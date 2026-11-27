#!/usr/bin/env python3
"""本地 mock IMAP 服务器:端到端验证 12306 邮件同步(无 TLS,仅本机测试)。

移植自 travel-notes/scripts/mock_imap.py,在原 UID 命令基础上兼容 JavaMail 的
序号命令(SEARCH / FETCH),文件夹名用 modified UTF-7(真实 IMAP 规范):

    python3 scripts/mock_imap.py                 # 正常模式
    ABORT_FIRST_FETCH=1 python3 scripts/mock_imap.py   # 模拟断线,验证自动重连

内置数据:
  INBOX/101   2026 新版购票通知  G4098 郑州东→上海虹桥(HTML+base64 UTF-8)
  INBOX/102   12306 营销邮件     C1234 武汉—汉口(必须被购票闸门挡住)
  归档/201    2013 老版购票通知  T164 上海一郑州(GB2312+base64,无年份日期)
"""
import base64
import os
import re
import socket
import struct

ABORT_FIRST_FETCH = os.environ.get("ABORT_FIRST_FETCH") == "1"
_abort_done = False


def gb2312_b64(s):
    return base64.b64encode(s.encode("gb2312")).decode()


def utf8_b64(s):
    return base64.b64encode(s.encode("utf-8")).decode()


def mutf7(s):
    """modified UTF-7(RFC 3501):非 ASCII 段用 &base64-,base64 的 / 换成 , 无填充。"""
    out = []
    for ch in s:
        if 0x20 <= ord(ch) <= 0x7E:
            out.append(ch)
        else:
            b = ch.encode("utf-16-be")
            enc = base64.b64encode(b).decode().rstrip("=").replace("/", ",")
            out.append("&" + enc + "-")
    return "".join(out)


def mutf7_decode(text):
    def repl(m):
        raw = base64.b64decode(m.group(1).replace(",", "/") + "==")
        return raw.decode("utf-16-be")

    return re.sub(r"&([0-9A-Za-z,]+)-", repl, text)


def make_raw(message_id, date, sender, subject_enc, content_type, cte, body_raw):
    header = (
        f"Message-ID: <{message_id}>\r\n"
        f"Date: {date}\r\n"
        f"From: {sender}\r\n"
        "To: test@qq.com\r\n"
        f"Subject: {subject_enc}\r\n"
        "MIME-Version: 1.0\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Transfer-Encoding: {cte}\r\n"
        "\r\n"
    )
    return header.encode() + body_raw


OLD_BODY = (
    "尊敬张三先生：您好！您在中国铁路客户服务中心网站（http://www.12306.cn）"
    "成功购买了1张车票，票款共计128.50元。所购车票信息如下："
    "1.张三，04月29日19:36，上海一郑州，T164次列车，10车091号，硬座，票价128.50元。"
    "请尽快选择如下方式之一办理换票手续后进站乘车："
    "方式一：请持购票时所使用的二代居民身份证原件到车站自动售票机换取纸质车票。"
    "方式二：请持购票时所使用二代居民身份证原件到车站售票窗口或铁路客票代售点换取纸质车票。"
    "方式三：在铁路客票代售点或自动售票机换取纸质车票时，"
    "如果购票时所使用的二代居民身份证不能识读，"
    "请持该二代居民身份证原件和订单号码E757718715到车站售票窗口换取纸质车票。"
    "温馨提示：请尽快换取纸质车票。"
)

HTML = """<html><body>
<div>您已成功购买以下车票:</div>
<table>
<tr><td>乘车日期</td><td>2026年10月07日</td></tr>
<tr><td>车次</td><td>G4098</td></tr>
<tr><td>出发/到达</td><td>郑州东 — 上海虹桥</td></tr>
<tr><td>开车时刻</td><td>20:48开</td></tr>
<tr><td>座位</td><td>05车04B号 二等座</td></tr>
<tr><td>票价</td><td>¥553.0元</td></tr>
<tr><td>乘车人</td><td>张三</td></tr>
</table>
<div>更多信息仅供参考,实际以车站公告为准。</div>
</body></html>"""

PROMO_BODY = "【铁路12306】C1234 武汉—汉口城际特惠,二等座 8.5元起,快来抢购!"

MAILS = {
    "INBOX": [
        (101, make_raw(
            "mock-101@mock.local", "Sun, 27 Sep 2026 08:00:00 +0800", "12306@12306.cn",
            "=?UTF-8?B?" + utf8_b64("您的订票信息") + "?=",
            'text/html; charset="utf-8"', "base64",
            (utf8_b64(HTML) + "\r\n").encode())),
        (102, make_raw(
            "mock-102@mock.local", "Mon, 28 Sep 2026 09:00:00 +0800", "12306@12306.cn",
            "=?UTF-8?B?" + utf8_b64("武汉—汉口城际特惠") + "?=",
            'text/plain; charset="utf-8"', "base64",
            (utf8_b64(PROMO_BODY) + "\r\n").encode())),
    ],
    "归档": [
        (201, make_raw(
            "mock-201@mock.local", "Thu, 11 Apr 2013 20:00:00 +0800", "12306<12306@rails.com.cn>",
            "=?GB2312?B?" + gb2312_b64("网上购票系统-用户支付通知") + "?=",
            'text/plain; Charset = "gb2312"', "base64",
            (gb2312_b64(OLD_BODY) + "\r\n").encode())),
    ],
}


def body_of(raw):
    return raw.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in raw else b""


def head_of(raw):
    return raw.split(b"\r\n\r\n", 1)[0] + b"\r\n\r\n"


def bodystructure_of(raw):
    """单部分邮件的 BODYSTRUCTURE:(type sub params NIL NIL cte size lines)"""
    head = raw.split(b"\r\n\r\n", 1)[0].decode("utf-8", "replace")

    def h(name):
        for line in head.split("\r\n"):
            if line.lower().startswith(name.lower() + ":"):
                return line[len(name) + 1:].strip()
        return None

    ct = h("Content-Type") or "text/plain"
    main = ct.split(";")[0].strip()
    mtype, _, subtype = main.partition("/")
    charset = None
    m = re.search(r'charset\s*=\s*"?([^";]+)"?', ct, re.I)
    if m:
        charset = m.group(1).strip()
    params = f'("CHARSET" "{charset}")' if charset else "NIL"
    cte = h("Content-Transfer-Encoding") or "7bit"
    body = body_of(raw)
    lines = body.count(b"\r\n") + 1
    # BODYSTRUCTURE(区别于 BODY)必须带 4 个扩展字段:MD5/disposition/language/location
    return f'("{mtype}" "{subtype}" {params} NIL NIL "{cte}" {len(body)} {lines} NIL NIL NIL NIL)'


def envelope_of(raw):
    """构造 IMAP ENVELOPE 响应:(date subject from sender reply-to to cc bcc in-reply-to message-id)"""
    head = raw.split(b"\r\n\r\n")[0].decode("utf-8", "replace")

    def h(name):
        for line in head.split("\r\n"):
            if line.lower().startswith(name.lower() + ":"):
                return line[len(name) + 1:].strip()
        return None

    date = h("Date")
    subject = h("Subject") or ""
    mid = h("Message-ID")
    fromv = h("From") or ""
    m = re.search(r"<([^>]+)>", fromv)
    addr = m.group(1) if m else fromv.strip()
    name_part = fromv[:m.start()].strip().strip('"') if m else ""
    local, host = addr.rsplit("@", 1) if "@" in addr else (addr, "")

    def addr_struct(nm, loc, host_):
        n = f'"{nm}"' if nm else "NIL"
        return f"({n} NIL \"{loc}\" \"{host_}\")"

    one = addr_struct(name_part, local, host)
    # from/sender/reply-to/to 都必须是"地址结构列表"(外层再包一层括号),否则 JavaMail 解析失败
    addr_list = f"({one})"
    to_list = f"({addr_struct('test', 'test', 'qq.com')})"
    return (f'("{date}" "{subject}" {addr_list} {addr_list} {addr_list} {to_list} '
            f'NIL NIL NIL "{mid}")')


def parse_seq_set(s):
    """解析 IMAP 序号/UID 集合:1,2,4:6 / 1:* → set 或 None(全部)"""
    out = set()
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            a, b = part.split(":", 1)
            if a == "*" or b == "*":
                return None
            out.update(range(int(a), int(b) + 1))
        elif part.isdigit():
            out.add(int(part))
    return out or None


def handle(conn):
    global _abort_done
    f = conn.makefile("rb")

    def send(s):
        conn.sendall(s.encode() if isinstance(s, str) else s)
        print("S:", s if isinstance(s, str) else s.decode("utf-8", "replace"), flush=True)

    send("* OK Mock IMAP4rev1 server ready\r\n")
    folder = "INBOX"
    for line in f:
        text = line.decode("utf-8", "replace").rstrip("\r\n")
        parts = text.split(" ")
        if not parts:
            continue
        tag, rest = parts[0], " ".join(parts[1:])
        up = rest.upper()
        print("C:", text, flush=True)
        if up.startswith("CAPABILITY"):
            # JavaMail 连接时会请求 CAPABILITY，必须回应未打标能力行
            send("* CAPABILITY IMAP4rev1 ID\r\n")
            send(f"{tag} OK CAPABILITY completed\r\n")
        elif up.startswith("ID"):
            send('* ID ("name" "Mock" "version" "1.0")\r\n')
            send(f"{tag} OK ID completed\r\n")
        elif up.startswith("LOGIN"):
            send(f"{tag} OK LOGIN completed\r\n")
        elif up.startswith("LIST"):
            for name in MAILS:
                send(f'* LIST () "/" "{mutf7(name)}"\r\n')
            send(f"{tag} OK LIST completed\r\n")
        elif up.startswith("SELECT") or up.startswith("EXAMINE"):
            # READ_ONLY 打开走 EXAMINE，与 SELECT 同样要回 EXISTS
            rest_dec = mutf7_decode(rest)
            for name in MAILS:
                if name in rest or name in rest_dec:
                    folder = name
                    break
            send(f"* {len(MAILS[folder])} EXISTS\r\n* 0 RECENT\r\n")
            send(f"{tag} OK [READ-WRITE] SELECT completed\r\n")
        elif up.startswith("UID SEARCH"):
            uids = " ".join(str(u) for u, _ in MAILS[folder])
            send(f"* SEARCH {uids}\r\n")
            send(f"{tag} OK SEARCH completed\r\n")
        elif up.startswith("SEARCH"):
            # JavaMail 序号 SEARCH:返回消息序号(1..N)
            seqs = " ".join(str(i) for i in range(1, len(MAILS[folder]) + 1))
            send(f"* SEARCH {seqs}\r\n")
            send(f"{tag} OK SEARCH completed\r\n")
        elif up.startswith("UID FETCH"):
            spec = rest[len("UID FETCH "):]
            uid_part, paren = spec.split(" (", 1)
            paren = "(" + paren
            mails = MAILS[folder]
            if uid_part != "1:*":
                wanted = {int(x) for x in uid_part.split(",")}
                mails = [(u, raw) for u, raw in mails if u in wanted]
            full_body = "BODY[]" in paren.replace("BODY.PEEK", "BODY")
            if full_body and ABORT_FIRST_FETCH and not _abort_done:
                _abort_done = True
                print("!! aborting connection mid-FETCH (simulated)", flush=True)
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                conn.close()
                return
            for seq, (uid, raw) in enumerate(mails, start=1):
                if paren == "(UID)":
                    send(f"* {seq} FETCH (UID {uid})\r\n")
                    continue
                if full_body:
                    payload, item = raw, "BODY[]"
                else:
                    head = raw.split(b"\r\n\r\n")[0] + b"\r\n\r\n"
                    payload, item = head, "BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)]"
                send(f"* {seq} FETCH (UID {uid} {item} {{{len(payload)}}}\r\n")
                conn.sendall(payload)
                send(")\r\n")
            send(f"{tag} OK FETCH completed\r\n")
        elif up.startswith("FETCH"):
            # JavaMail 序号 FETCH:支持 ENVELOPE/BODYSTRUCTURE(结构化)与 BODY[x](literal)
            spec = rest[len("FETCH "):]
            seq_part, paren = spec.split(" (", 1)
            paren = "(" + paren
            norm = paren.replace("BODY.PEEK", "BODY")
            wants_env = "ENVELOPE" in norm
            wants_bs = "BODYSTRUCTURE" in norm
            wants_body = "BODY[" in norm
            mails = MAILS[folder]
            seqs = parse_seq_set(seq_part)
            for seq, (uid, raw) in enumerate(mails, start=1):
                if seqs is not None and seq not in seqs:
                    continue
                items = []
                if wants_env:
                    items.append("ENVELOPE " + envelope_of(raw))
                if wants_bs:
                    items.append("BODYSTRUCTURE " + bodystructure_of(raw))
                if wants_body:
                    if ABORT_FIRST_FETCH and not _abort_done:
                        _abort_done = True
                        print("!! aborting connection mid-FETCH (simulated)", flush=True)
                        conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                        conn.close()
                        return
                    m = re.search(r"BODY\[([^\]]*)\]", norm)
                    section = m.group(1) if m else ""
                    if section == "":
                        payload = raw
                    elif section.upper().startswith("HEADER"):
                        payload = head_of(raw)
                    else:
                        payload = body_of(raw)
                    head = " ".join(items) + " " if items else ""
                    send(f"* {seq} FETCH ({head}BODY[{section}] {{{len(payload)}}}\r\n")
                    conn.sendall(payload)
                    send(")\r\n")
                elif items:
                    send(f"* {seq} FETCH ({' '.join(items)})\r\n")
            send(f"{tag} OK FETCH completed\r\n")
        elif up.startswith("LOGOUT"):
            send(f"{tag} OK LOGOUT completed\r\n")
            return
        else:
            send(f"{tag} OK completed\r\n")


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", 8025))
    srv.listen(5)
    print("mock IMAP on 0.0.0.0:8025", flush=True)
    while True:
        conn, addr = srv.accept()
        print("client", addr, flush=True)
        try:
            handle(conn)
        except Exception as e:  # noqa: BLE001 - 测试脚本,出错打印后继续
            print("handler error:", e, flush=True)
        finally:
            try:
                conn.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()

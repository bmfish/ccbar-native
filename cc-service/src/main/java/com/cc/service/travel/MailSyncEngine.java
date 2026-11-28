package com.cc.service.travel;

import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

import org.eclipse.angus.mail.imap.IMAPFolder;
import org.eclipse.angus.mail.imap.IMAPStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import com.cc.service.admin.AdminTimes;
import com.cc.service.push.PushService;
import com.cc.service.settings.AppSettings;
import com.fasterxml.jackson.databind.ObjectMapper;

import jakarta.mail.Address;
import jakarta.mail.Folder;
import jakarta.mail.FolderClosedException;
import jakarta.mail.Message;
import jakarta.mail.MessagingException;
import jakarta.mail.Multipart;
import jakarta.mail.Part;
import jakarta.mail.Session;
import jakarta.mail.StoreClosedException;
import jakarta.mail.internet.InternetAddress;
import jakarta.mail.internet.MimeMessage;
import jakarta.mail.search.AndTerm;
import jakarta.mail.search.ComparisonTerm;
import jakarta.mail.search.FromStringTerm;
import jakarta.mail.search.SearchTerm;
import jakarta.mail.search.SentDateTerm;

/**
 * 12306 订票邮件同步引擎（高铁笔记 iOS 端 MailSyncEngine 的服务端移植）。
 *
 * <p>数据流：QQ 邮箱 IMAP → 全文件夹 SEARCH(FROM "12306") → 批量拉取并解析
 * → 四阶段过滤（购票闸门 / 退票作废 / 改签换新 / 候选去重）→ travel_mail_candidate
 * → 要素齐全自动导入 travel_ticket。trip_key（车次|出发|到达|yyyy.MM.dd）跨邮件全局去重。</p>
 *
 * <p>QQ 邮箱要求登录后先发 IMAP ID 命令表明客户端身份，否则可能拒绝部分操作。</p>
 */
@Component
public class MailSyncEngine {

    private static final Logger log = LoggerFactory.getLogger(MailSyncEngine.class);

    /** 照搬 iOS 端常量：跳过的系统文件夹关键字（含 QQ 中文命名）。 */
    private static final List<String> EXCLUDED_FOLDER_HINTS = List.of(
            "sent", "已发送", "drafts", "草稿", "junk", "垃圾", "spam", "trash", "已删除", "deleted");
    private static final String SEARCH_FROM = "12306";
    private static final String FULL_HISTORY_SINCE = "01-Jan-2010";
    private static final int LOGIN_RETRIES = 3;
    private static final int FETCH_RETRIES = 6;
    private static final long RETRY_SLEEP_MS = 2000;
    private static final DateTimeFormatter TRIP_DATE = DateTimeFormatter.ofPattern("yyyy.MM.dd");
    private static final DateTimeFormatter IMAP_DATE = DateTimeFormatter.ofPattern("dd-MMM-yyyy", Locale.ENGLISH);

    public record SyncSummary(
            String mode,
            long mailsFetched,
            long mailsMatched,
            long candidatesCreated,
            long ticketsImported,
            long refunds,
            long changes,
            long elapsedMs,
            OffsetDateTime finishedAt) {
    }

    /** 一封已解码的候选邮件（已通过购票闸门或属退票/改签）。 */
    private record ParsedMail(
            String folder,
            String from,
            String subject,
            LocalDateTime sentDate,
            String orderNo,
            boolean refund,
            boolean change,
            List<TicketMailParser.ParsedTicket> tickets) {
    }

    private final TravelRepository repository;
    private final ObjectMapper objectMapper;
    private final PushService pushService;
    private final AppSettings settings;

    private final int batchSize;
    private final int timeoutMs;

    private final AtomicBoolean running = new AtomicBoolean(false);

    public MailSyncEngine(
            TravelRepository repository,
            ObjectMapper objectMapper,
            PushService pushService,
            AppSettings settings,
            @Value("${app.travel.fetch.batch-size:20}") int batchSize,
            @Value("${app.travel.fetch.timeout-ms:90000}") int timeoutMs) {
        this.repository = repository;
        this.objectMapper = objectMapper;
        this.pushService = pushService;
        this.settings = settings;
        this.batchSize = Math.max(batchSize, 1);
        this.timeoutMs = Math.max(timeoutMs, 10000);
    }

    /** 邮箱配置来自「系统设置」（数据库优先、环境变量兜底），改配置即生效。 */
    private String mailHost() {
        return settings.get(AppSettings.TRAVEL_MAIL_HOST);
    }

    private int mailPort() {
        return settings.getInt(AppSettings.TRAVEL_MAIL_PORT, 993);
    }

    private String mailEmail() {
        return settings.get(AppSettings.TRAVEL_MAIL_EMAIL);
    }

    private String mailAuthCode() {
        return settings.get(AppSettings.TRAVEL_MAIL_AUTH_CODE);
    }

    private String mailOwner() {
        return settings.get(AppSettings.TRAVEL_MAIL_OWNER);
    }

    public boolean isRunning() {
        return running.get();
    }

    public boolean credentialsConfigured() {
        return !mailEmail().isEmpty() && !mailAuthCode().isEmpty();
    }

    /** 距上次成功同步不足「同步节流」分钟数则跳过自动同步。 */
    public boolean throttled() {
        int minIntervalMinutes = settings.getInt(AppSettings.TRAVEL_MIN_INTERVAL_MINUTES, 30);
        if (minIntervalMinutes <= 0) {
            return false;
        }
        OffsetDateTime last = repository.getSyncState().lastSyncAt();
        return last != null && last.plusMinutes(minIntervalMinutes).isAfter(AdminTimes.now());
    }

    /**
     * 执行一次同步。同一时刻只允许一个同步任务，重复触发抛 IllegalStateException。
     *
     * @param fullHistory true 表示全量重新同步（解析规则升级后补数据用）
     */
    public SyncSummary sync(boolean fullHistory) {
        if (!running.compareAndSet(false, true)) {
            throw new IllegalStateException("同步已在进行中");
        }
        try {
            return doSync(fullHistory);
        } finally {
            running.set(false);
        }
    }

    private SyncSummary doSync(boolean fullHistory) {
        if (!credentialsConfigured()) {
            throw new IllegalStateException("未配置邮箱账号或授权码：请在管理台「系统设置」填写，或配置环境变量 TRAVEL_MAIL_EMAIL / TRAVEL_MAIL_AUTH_CODE");
        }
        long started = System.currentTimeMillis();
        log.info("12306 邮件同步开始（{}，水位 {}）", fullHistory ? "全量" : "增量", sinceDate(fullHistory));
        List<ParsedMail> mails = new ArrayList<>();
        int folderCount = 0;

        try (IMAPStore store = openStore()) {
            sendIdCommand(store);
            String since = sinceDate(fullHistory);
            List<String> folders = listFolderNames(store);
            folderCount = folders.size();
            for (String folderName : folders) {
                int before = mails.size();
                fetchFolder(store, folderName, since, mails);
                if (mails.size() > before) {
                    log.info("12306 文件夹 {} 命中 {} 封", folderName, mails.size() - before);
                }
            }
        } catch (Exception e) {
            if (e instanceof RuntimeException re) {
                throw re;
            }
            throw new IllegalStateException("邮件同步失败：" + e.getMessage(), e);
        }
        log.info("12306 邮件拉取完成：{} 个文件夹，{} 封待解析", folderCount, mails.size());

        // 阶段一：邮件按发件时间升序（先老后新，改签取最后一封）
        mails.sort(Comparator.comparing(ParsedMail::sentDate,
                Comparator.nullsLast(Comparator.naturalOrder())));

        // 阶段二：退票邮件解析出的 tripKey 全部作废
        Set<String> refundKeys = new HashSet<>();
        for (ParsedMail mail : mails) {
            if (mail.refund()) {
                mail.tickets().forEach(t -> refundKeys.add(tripKeyOf(t)));
            }
        }

        // 阶段三：改签按订单号分组，同订单只保留最后一封改签邮件的新票
        Map<String, ParsedMail> lastChangeByOrder = new HashMap<>();
        for (ParsedMail mail : mails) {
            if (!mail.change() || mail.orderNo() == null) {
                continue;
            }
            lastChangeByOrder.put(mail.orderNo(), mail); // 升序遍历，覆盖即最后一封
        }
        Set<String> changeValidKeys = new HashSet<>();
        Set<String> invalidatedKeys = new HashSet<>();
        for (Map.Entry<String, ParsedMail> entry : lastChangeByOrder.entrySet()) {
            entry.getValue().tickets().forEach(t -> changeValidKeys.add(tripKeyOf(t)));
            for (ParsedMail mail : mails) {
                if (mail == entry.getValue() || mail.refund() || !entry.getKey().equals(mail.orderNo())) {
                    continue;
                }
                mail.tickets().forEach(t -> invalidatedKeys.add(tripKeyOf(t)));
            }
        }
        Set<String> changedKeys = new HashSet<>(invalidatedKeys);
        changedKeys.removeAll(changeValidKeys);

        // 阶段四：建候选（tripKey 跨邮件跨批次全局去重）
        Set<String> existing = new HashSet<>(repository.allTicketTripKeys());
        existing.addAll(repository.allCandidateTripKeys());
        long candidatesCreated = 0;
        long mailsMatched = 0;
        for (ParsedMail mail : mails) {
            if (mail.refund()) {
                continue;
            }
            if (mail.change() && mail.orderNo() != null && mail != lastChangeByOrder.get(mail.orderNo())) {
                continue;
            }
            mailsMatched++;
            for (TicketMailParser.ParsedTicket ticket : mail.tickets()) {
                String key = tripKeyOf(ticket);
                if (key.isBlank() || existing.contains(key) || refundKeys.contains(key)) {
                    continue;
                }
                if (invalidatedKeys.contains(key) && !changeValidKeys.contains(key)) {
                    continue;
                }
                if (repository.insertCandidate(key, ticket.rideDate(), ticket.departTimeText(),
                        ticket.trainNo(), ticket.fromStation(), ticket.toStation(), ticket.coach(),
                        ticket.seat(), ticket.seatClass(), priceOf(ticket), ticket.passenger(),
                        mail.orderNo(), "12306")) {
                    candidatesCreated++;
                }
                existing.add(key);
            }
        }

        // 存量票根的退票/改签状态随邮件落库
        long refundMarked = repository.markTicketsRefunded(refundKeys);
        long changeMarked = repository.markTicketsChanged(changedKeys);

        // 自动导入：车次+出发+到达+日期 齐全的候选直接转正式票根，残缺的留待人工确认
        TravelRepository.ImportResult importResult = importCompleteCandidates();

        SyncSummary summary = new SyncSummary(fullHistory ? "full" : "incremental",
                mails.size(), mailsMatched, candidatesCreated, importResult.imported(),
                refundMarked, changeMarked,
                System.currentTimeMillis() - started, AdminTimes.now());
        repository.markSynced(mailEmail(), mailOwner(), fullHistory, toJson(summary), AdminTimes.now());
        log.info("12306 邮件同步完成：{} 封邮件，新增候选 {}，导入 {}，退票标记 {}，改签标记 {}",
                mails.size(), candidatesCreated, importResult.imported(),
                refundMarked, changeMarked);

        // 增量同步发现新票根时推送提醒（全量重同步是维护操作，不推送避免刷屏）
        if (!fullHistory && importResult.imported() > 0) {
            pushNewTickets(importResult.imported(), importResult.samples());
        }
        return summary;
    }

    private void pushNewTickets(int imported, List<String> samples) {
        String preview = String.join("；", samples.subList(0, Math.min(samples.size(), 3)));
        if (samples.size() > 3) {
            preview += " 等";
        }
        try {
            pushService.sendEventNotification("新票据",
                    "同步新增 " + imported + " 张票根：" + preview, "旅行票据");
        } catch (Exception e) {
            log.warn("新票根推送失败: {}", e.getMessage());
        }
    }

    /* ---------- IMAP 连接 ---------- */

    private IMAPStore openStore() throws MessagingException, InterruptedException {
        String host = mailHost();
        int port = mailPort();
        // 明文联调：mock 服务器（127.0.0.1 / localhost 或 8025 端口）与 iOS 端约定一致
        boolean plaintext = host.equals("127.0.0.1") || host.equals("localhost") || port == 8025;
        Session session = Session.getInstance(sessionProps(plaintext));
        MessagingException lastFailure = null;
        for (int attempt = 1; attempt <= LOGIN_RETRIES; attempt++) {
            IMAPStore store = (IMAPStore) session.getStore("imap");
            try {
                store.connect(host, port, mailEmail(), mailAuthCode());
                return store;
            } catch (MessagingException e) {
                String message = String.valueOf(e.getMessage()).toLowerCase(Locale.ROOT);
                if (message.contains("bad") || message.contains("authentication")) {
                    throw e; // 协议明确拒绝（授权码错误）不重试
                }
                lastFailure = e;
                log.warn("IMAP 连接失败（第 {}/{} 次）：{}", attempt, LOGIN_RETRIES, e.getMessage());
                Thread.sleep(RETRY_SLEEP_MS);
            }
        }
        throw lastFailure != null ? lastFailure
                : new MessagingException("IMAP 连接失败");
    }

    private java.util.Properties sessionProps(boolean plaintext) {
        java.util.Properties props = new java.util.Properties();
        props.setProperty("mail.imap.connectiontimeout", "30000");
        props.setProperty("mail.imap.timeout", String.valueOf(timeoutMs));
        props.setProperty("mail.imap.fetchsize", "1048576");
        props.setProperty("mail.imap.ssl.enable", String.valueOf(!plaintext));
        // 老邮件常是裸 GB2312 字节流却没声明 charset，兜底 GB18030（对应 iOS 端 MIME.swift 规则）
        props.setProperty("mail.mime.defaultcharset", "GB18030");
        // 允许用 -Dmail.debug=true 打开协议级 trace（联调排障用）
        props.setProperty("mail.debug", String.valueOf(Boolean.getBoolean("mail.debug")));
        return props;
    }

    /** QQ 邮箱要求表明客户端身份：ID ("name" "TrainTicketDiary" "version" "1.0")。 */
    private void sendIdCommand(IMAPStore store) throws MessagingException {
        try {
            IMAPFolder inbox = (IMAPFolder) store.getFolder("INBOX");
            inbox.doCommand(protocol -> {
                protocol.id(Map.of("name", "TrainTicketDiary", "version", "1.0"));
                return null;
            });
        } catch (MessagingException e) {
            log.debug("IMAP ID 命令发送失败（不影响同步）: {}", e.getMessage());
        }
    }

    /** 增量用上次成功同步的水位（精确到天），全量/首次从 2010 年起。 */
    private String sinceDate(boolean fullHistory) {
        if (fullHistory) {
            return FULL_HISTORY_SINCE;
        }
        OffsetDateTime last = repository.getSyncState().lastSyncAt();
        if (last == null) {
            return FULL_HISTORY_SINCE;
        }
        return last.atZoneSameInstant(AdminTimes.ZONE).toLocalDate().format(IMAP_DATE);
    }

    /** 全文件夹扫描（对应 iOS 端 LIST "" "*"）：老邮件可能被归档到自建文件夹，INBOX 必扫。 */
    private List<String> listFolderNames(IMAPStore store) throws MessagingException {
        IMAPFolder probe = (IMAPFolder) store.getFolder("INBOX");
        org.eclipse.angus.mail.imap.protocol.ListInfo[] infos = (org.eclipse.angus.mail.imap.protocol.ListInfo[])
                probe.doCommand(protocol -> protocol.list("", "*"));
        List<String> names = new ArrayList<>();
        boolean inboxFound = false;
        if (infos != null) {
            for (org.eclipse.angus.mail.imap.protocol.ListInfo info : infos) {
                String name = info.name;
                if (name == null || name.isBlank()) {
                    continue;
                }
                if ("INBOX".equalsIgnoreCase(name)) {
                    names.add(0, name);
                    inboxFound = true;
                    continue;
                }
                if (!info.canOpen || excludedByName(name.toLowerCase(Locale.ROOT))) {
                    continue;
                }
                names.add(name);
            }
        }
        if (!inboxFound) {
            names.add(0, "INBOX");
        }
        return names;
    }

    private boolean excludedByName(String lowerName) {
        for (String hint : EXCLUDED_FOLDER_HINTS) {
            if (lowerName.contains(hint)) {
                return true;
            }
        }
        return false;
    }

    /* ---------- 单文件夹拉取（断线重连最多 6 次，照搬 iOS resilient 语义） ---------- */

    private void fetchFolder(IMAPStore store, String folderName, String since, List<ParsedMail> out) {
        for (int attempt = 1; attempt <= FETCH_RETRIES; attempt++) {
            try {
                fetchFolderOnce(store, folderName, since, out);
                return;
            } catch (FolderClosedException | StoreClosedException e) {
                log.warn("文件夹 {} 拉取中断（第 {}/{} 次），重连续传: {}",
                        folderName, attempt, FETCH_RETRIES, e.getMessage());
                reconnectQuietly(store);
            } catch (Exception e) {
                if (attempt >= FETCH_RETRIES || !transientError(e)) {
                    log.warn("文件夹 {} 拉取失败，跳过: {}", folderName, e.getMessage());
                    return;
                }
                log.warn("文件夹 {} 拉取出错（第 {}/{} 次）: {}",
                        folderName, attempt, FETCH_RETRIES, e.getMessage());
                reconnectQuietly(store);
                sleepQuietly();
            }
        }
    }

    private void fetchFolderOnce(IMAPStore store, String folderName, String since, List<ParsedMail> out)
            throws Exception {
        try (IMAPFolder folder = (IMAPFolder) store.getFolder(folderName)) {
            if (!folder.exists()) {
                return;
            }
            folder.open(Folder.READ_ONLY);
            Message[] found = folder.search(searchSince(since));
            if (found.length == 0) {
                return;
            }
            jakarta.mail.FetchProfile profile = new jakarta.mail.FetchProfile();
            profile.add(jakarta.mail.FetchProfile.Item.ENVELOPE);
            // 20 封一批预取信封；正文在各消息首次访问时懒加载（对应 iOS 端 20/批 UID FETCH）
            for (int start = 0; start < found.length; start += batchSize) {
                int end = Math.min(start + batchSize, found.length);
                Message[] batch = Arrays.copyOfRange(found, start, end);
                folder.fetch(batch, profile);
                for (Message message : batch) {
                    if (!(message instanceof MimeMessage mime) || mime.isExpunged()) {
                        continue;
                    }
                    try {
                        ParsedMail mail = decode(folderName, mime);
                        if (mail != null) {
                            out.add(mail);
                        }
                    } catch (Exception e) {
                        log.debug("解码邮件失败（folder={}, subject={}）: {}",
                                folderName, mime.getSubject(), e.getMessage());
                    }
                }
            }
        }
    }

    private SearchTerm searchSince(String since) {
        LocalDate sinceDate = LocalDate.parse(since, IMAP_DATE);
        SentDateTerm dateTerm = new SentDateTerm(ComparisonTerm.GE, java.sql.Date.valueOf(sinceDate));
        return new AndTerm(new FromStringTerm(SEARCH_FROM), dateTerm);
    }

    /** 解码单封邮件：退票/改签分类、购票双重闸门、解析票根（对应 iOS decodeRecords）。 */
    private ParsedMail decode(String folderName, MimeMessage message) throws Exception {
        Address[] addresses = message.getFrom();
        String from = addresses != null && addresses.length > 0 && addresses[0] instanceof InternetAddress ia
                ? ia.getAddress()
                : "";
        String subject = orEmpty(message.getSubject());
        LocalDateTime sentDate = toLocalDateTime(message.getSentDate());
        if (sentDate == null) {
            sentDate = toLocalDateTime(message.getReceivedDate());
        }
        String body = extractText(message);

        boolean refund = TicketMailParser.isRefundSubject(subject);
        boolean change = TicketMailParser.isChangeSubject(subject);
        if (!refund && !change) {
            // 两道闸门挡住 12306 营销/通知邮件，防止拼出假行程
            if (!TicketMailParser.looksLikeTicketMail(from, subject)
                    || !TicketMailParser.looksLikePurchase(subject, body)) {
                return null;
            }
        }
        List<TicketMailParser.ParsedTicket> tickets =
                TicketMailParser.parse(subject, body, mailOwner().isEmpty() ? null : mailOwner(), sentDate);
        List<String> orderNos = TicketMailParser.extractOrderNos(body);
        return new ParsedMail(folderName, from, subject, sentDate,
                orderNos.isEmpty() ? null : orderNos.get(0), refund, change, tickets);
    }

    /* ---------- 正文提取（HTML 优先，GB18030 兜底） ---------- */

    private String extractText(Part part) throws Exception {
        StringBuilder html = new StringBuilder();
        StringBuilder plain = new StringBuilder();
        collectText(part, html, plain, 0);
        if (!html.isEmpty()) {
            return stripHtml(html.toString());
        }
        return plain.toString();
    }

    private void collectText(Part part, StringBuilder html, StringBuilder plain, int depth) throws Exception {
        if (depth > 10) {
            return;
        }
        if (part.isMimeType("multipart/*")) {
            Object content = part.getContent();
            if (content instanceof Multipart multipart) {
                for (int i = 0; i < multipart.getCount(); i++) {
                    collectText(multipart.getBodyPart(i), html, plain, depth + 1);
                }
            }
            return;
        }
        if (part.isMimeType("text/html")) {
            if (html.isEmpty()) {
                html.append(decodeText(part));
            }
            return;
        }
        if (part.isMimeType("text/plain")) {
            if (plain.isEmpty()) {
                plain.append(decodeText(part));
            }
        }
        // 附件等其余类型不参与解析
    }

    /** 按声明字符集解码；乱码率高或未声明时依次尝试 UTF-8 / GB18030（对应 iOS MIME.swift）。 */
    private String decodeText(Part part) throws IOException, MessagingException {
        String declared = declaredCharset(part.getContentType());
        byte[] bytes;
        try (var in = part.getInputStream()) {
            bytes = in.readAllBytes();
        }
        if (declared != null) {
            String decoded = decodeBytes(bytes, declared);
            if (mojibakeRatio(decoded) < 0.02) {
                return decoded;
            }
        }
        String utf8 = new String(bytes, StandardCharsets.UTF_8);
        if (mojibakeRatio(utf8) < 0.02) {
            return utf8;
        }
        return new String(bytes, Charset.forName("GB18030"));
    }

    private String declaredCharset(String contentType) {
        if (contentType == null) {
            return null;
        }
        String lower = contentType.toLowerCase(Locale.ROOT);
        int idx = lower.indexOf("charset=");
        if (idx < 0) {
            return null;
        }
        String value = contentType.substring(idx + "charset=".length());
        value = value.split(";")[0].trim();
        if (value.startsWith("\"")) {
            value = value.substring(1, value.endsWith("\"") ? value.length() - 1 : value.length());
        }
        return value.isBlank() ? null : value;
    }

    private String decodeBytes(byte[] bytes, String charset) {
        try {
            return new String(bytes, Charset.forName(charset));
        } catch (Exception e) {
            return new String(bytes, StandardCharsets.UTF_8);
        }
    }

    private double mojibakeRatio(String text) {
        if (text.isEmpty()) {
            return 0;
        }
        long bad = text.chars().filter(c -> c == '�').count();
        return (double) bad / text.length();
    }

    private String stripHtml(String html) {
        String text = html.replaceAll("(?is)<(script|style)[^>]*>.*?</\\1>", " ");
        text = text.replaceAll("<[^>]+>", " ");
        text = text.replace("&nbsp;", " ")
                .replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&#39;", "'");
        text = text.replaceAll("&#x([0-9a-fA-F]+);", " ");
        return text.replaceAll("[ \\t\\r\\n\\f\\u00a0]+", " ").trim();
    }

    /* ---------- 候选导入与水位 ---------- */

    /** 要素齐全（车次+出发+到达+日期）的候选自动转正式票根。 */
    private TravelRepository.ImportResult importCompleteCandidates() {
        int imported = 0;
        List<String> samples = new ArrayList<>();
        List<Long> processed = new ArrayList<>();
        for (TravelRepository.CandidateRow row : repository.allCandidates()) {
            if (row.imported() || row.dismissed()) {
                continue;
            }
            if (row.rideDate() == null || isBlank(row.trainNo()) || isBlank(row.fromStation())
                    || isBlank(row.toStation())) {
                continue;
            }
            boolean inserted = repository.insertTicket(row.tripKey(), row.rideDate(), row.departTimeText(),
                    row.trainNo(), row.fromStation(), row.toStation(), row.coach(), row.seat(),
                    row.seatClass(), row.price(), row.passenger(), row.source());
            processed.add(row.id());
            if (inserted) {
                imported++;
                samples.add(TravelRepository.describeCandidate(row));
            }
        }
        repository.markCandidatesImported(processed);
        return new TravelRepository.ImportResult(imported, samples);
    }

    /** 手动确认导入（允许要素残缺，但至少要有乘车日期）。 */
    public TravelRepository.ImportResult importCandidates(List<Long> ids) {
        return repository.importCandidates(ids);
    }

    /* ---------- 工具 ---------- */

    private static String tripKeyOf(TicketMailParser.ParsedTicket t) {
        String date = t.rideDate() == null ? "" : t.rideDate().format(TRIP_DATE);
        return String.join("|",
                orEmpty(t.trainNo()), orEmpty(t.fromStation()), orEmpty(t.toStation()), date);
    }

    private static java.math.BigDecimal priceOf(TicketMailParser.ParsedTicket t) {
        return t.price() == null ? null : java.math.BigDecimal.valueOf(t.price());
    }

    private static String orEmpty(String value) {
        return value == null ? "" : value.trim();
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private static LocalDateTime toLocalDateTime(java.util.Date date) {
        return date == null ? null : LocalDateTime.ofInstant(date.toInstant(), AdminTimes.ZONE);
    }

    private String toJson(SyncSummary summary) {
        try {
            return objectMapper.writeValueAsString(summary);
        } catch (IOException e) {
            return "{\"mode\":\"" + summary.mode() + "\"}";
        }
    }

    private boolean transientError(Exception e) {
        String message = String.valueOf(e.getMessage()).toLowerCase(Locale.ROOT);
        return message.contains("connection") || message.contains("timeout")
                || message.contains("disconnect") || message.contains("not connected")
                || message.contains("socket") || message.contains("byenow")
                || e instanceof IOException;
    }

    private void reconnectQuietly(IMAPStore store) {
        try {
            if (!store.isConnected()) {
                store.connect(mailHost(), mailPort(), mailEmail(), mailAuthCode());
            }
        } catch (MessagingException e) {
            log.warn("IMAP 重连失败: {}", e.getMessage());
        }
    }

    private void sleepQuietly() {
        try {
            Thread.sleep(RETRY_SLEEP_MS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}

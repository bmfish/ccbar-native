package com.cc.service.travel;

import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 12306 订票邮件正文解析器:从邮件正文启发式抽取候选票根,候选一律经用户确认后入库。
 * 忠实移植自 iOS TravelNotes 的 TicketMailParser.swift,行为保持一致。
 */
public final class TicketMailParser {

    private TicketMailParser() {}

    /** 解析出的候选票根(Swift 版 ParsedTicket + 新增 orderNo 便于主工程落库) */
    public record ParsedTicket(String trainNo, String fromStation, String toStation,
            LocalDate rideDate, String departTimeText /*HH:mm*/, String coach, String seat,
            String seatClass, Double price, String passenger, String orderNo) {}

    /** 席别词表,按优先级顺序取正文中出现的第一个 */
    private static final List<String> SEAT_CLASS_OPTIONS = List.of(
            "商务座", "优选一等座", "一等座", "二等座", "软卧", "硬卧", "动卧", "软座", "硬座", "无座");

    /** 12306 邮件尾部的样板文字,正文在这些标记处截断,防止拼出假行程 */
    private static final String[] TRUNCATE_MARKERS = {"温馨提示", "退票规则", "铁路旅客禁止"};

    /** 严格分隔符站对;「一」单独一档只给 2015 年前的老邮件当破折号用 */
    private static final String STRICT_SEPARATORS = "-—－–—至到~→＞>";
    private static final String LOOSE_SEPARATORS = STRICT_SEPARATORS + "一";

    private static Pattern compile(String regex) {
        // UNICODE_CHARACTER_CLASS:与 Swift NSRegularExpression(ICU)一致,\s 认全角空格、\d 认 Unicode 数字
        return Pattern.compile(regex, Pattern.UNICODE_CHARACTER_CLASS);
    }

    // 车次号:前后不能是字母数字,避免命中订单号(如 EC58571374 里的 C5857);
    // 纯数字车次(1461次列车)没有字母前缀,靠「次列车」后缀锚定
    private static final Pattern TRAIN_PATTERN =
            compile("(?<![A-Za-z0-9])(?:[GDCTKZLYS]\\d{1,4}(?!\\d)|\\d{1,4}(?=次列车))");

    private static final Pattern TIME_PATTERN = compile("([01]?\\d|2[0-3]):[0-5]\\d");

    // 邮件里的编号乘车人列表("1.张三," "2.高小玉,"),结尾逗号全角半角都要认:老邮件用的是半角逗号
    private static final Pattern PASSENGER_ITEM_PATTERN = compile("\\d{1,2}\\s*[.、．]\\s*([一-龥]{2,4})[，,]");

    private static final Pattern FULL_DATE_PATTERN =
            compile("20\\d{2}\\s*[年\\-/.]\\s*\\d{1,2}\\s*[月\\-/.]\\s*\\d{1,2}\\s*日?");
    private static final Pattern BARE_DATE_PATTERN = compile("\\d{1,2}\\s*月\\s*\\d{1,2}\\s*日");
    private static final Pattern DATE_PARTS_PATTERN =
            compile("(20\\d{2})\\s*[年\\-/.]\\s*(\\d{1,2})\\s*[月\\-/.]\\s*(\\d{1,2})");
    private static final Pattern MONTH_DAY_PATTERN = compile("(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*日");

    private static final Pattern PRICE_PATTERN = compile("[¥￥]\\s*(\\d+(\\.\\d{1,2})?)|(\\d+(\\.\\d{1,2})?)\\s*元");
    private static final Pattern COACH_SEAT_PATTERN = compile("(\\d{1,2})\\s*车\\s*([0-9]{1,3}[A-Z]?\\s*号?|[上下中]铺)");

    private static final Pattern ORDER_NO_PATTERN = compile("订单号码\\s*([A-Z0-9]{6,16})");

    // 字面兜底:两侧都带「站」字的站对(北京丰台站-深圳东站),不查站名表直接按形态提取
    private static final Pattern LITERAL_PAIR_PATTERN = compile(
            "(?<![一-龥])([一-龥]{2,5})站\\s*[-—－–—至到~→＞>]{1,3}\\s*([一-龥]{2,5})站(?![一-龥])");

    // 站名表 3400+ 站拼成 alternation 大正则,长名在前;站名表加载失败时为 null,自动退到字面兜底
    private static final Pattern STRICT_PAIR_PATTERN = makePairPattern(STRICT_SEPARATORS);
    private static final Pattern LOOSE_PAIR_PATTERN = makePairPattern(LOOSE_SEPARATORS);
    private static final Pattern STATION_SCAN_PATTERN = makeStationScanPattern();

    private static final DateTimeFormatter DOT_DATE = DateTimeFormatter.ofPattern("yyyy.MM.dd", Locale.ROOT);

    // ---- 对外 API ----

    /**
     * 判断这封邮件是否像订票通知(发件人/主题包含 12306 或购票关键词);退票/退单不算乘车。
     */
    public static boolean looksLikeTicketMail(String from, String subject) {
        String s = ((from == null ? "" : from) + " " + (subject == null ? "" : subject)).toLowerCase(Locale.ROOT);
        if (s.contains("退票") || s.contains("退单")) return false;
        if (s.contains("12306")) return true;
        String[] keywords = {"车票", "购票", "订票", "行程", "火车票"};
        for (String keyword : keywords) {
            if (s.contains(keyword)) return true;
        }
        return false;
    }

    /**
     * 像"购票通知"才收:12306 的营销邮件也带车次站名,直接解析会拼出没去过的假行程。
     */
    public static boolean looksLikePurchase(String subject, String body) {
        String s = (subject == null ? "" : subject) + " " + (body == null ? "" : body);
        String[] markers = {"订单号", "车票信息", "乘车人", "换票", "取票", "席别", "座位"};
        for (String marker : markers) {
            if (s.contains(marker)) return true;
        }
        return false;
    }

    /** 退票/退单主题(不算乘车) */
    public static boolean isRefundSubject(String subject) {
        return subject != null && (subject.contains("退票") || subject.contains("退单"));
    }

    /** 改签主题 */
    public static boolean isChangeSubject(String subject) {
        return subject != null && subject.contains("改签");
    }

    /** 「订单号码」后的订单号([A-Z0-9]{6,16}),按出现顺序去重 */
    public static List<String> extractOrderNos(String body) {
        List<String> result = new ArrayList<>();
        if (body == null || body.isEmpty()) return result;
        for (OrderHit hit : findOrderNos(body)) {
            if (!result.contains(hit.value())) result.add(hit.value());
        }
        return result;
    }

    /** 行程去重键:"{trainNo}|{from}|{to}|{yyyy.MM.dd}"(空字段以空串占位) */
    public static String tripKey(ParsedTicket t) {
        if (t == null) return "";
        String date = t.rideDate() != null ? t.rideDate().format(DOT_DATE) : "";
        return nvl(t.trainNo()) + "|" + nvl(t.fromStation()) + "|" + nvl(t.toStation()) + "|" + date;
    }

    /**
     * 从订票邮件正文解析候选票根。
     * subject 仅保持与 Swift 同构的签名(Swift 实现同样未用到);owner 为收件人姓名,用于只保留本人票;
     * mailDate 为邮件时间,老邮件"04月29日"这类无年份日期按它推断年份。
     */
    public static List<ParsedTicket> parse(String subject, String bodyText, String owner, LocalDateTime mailDate) {
        String text = bodyText == null ? "" : bodyText;
        // 截掉 12306 邮件尾部的"温馨提示/退票规则"样板文字,防止拼出假行程
        for (String marker : TRUNCATE_MARKERS) {
            int idx = text.indexOf(marker);
            if (idx >= 0) text = text.substring(0, idx);
        }
        if (text.isEmpty()) return List.of();

        List<Hit> trainMatches = allMatches(TRAIN_PATTERN, text);
        if (trainMatches.isEmpty()) return List.of();

        // 邮件里的编号乘车人列表("1.张三," "2.高小玉,"),用于只保留本人票
        List<PassengerItem> passengerItems = passengerItems(text);

        // 严格分隔符(-—至到等)的站对优先;整篇都没有严格站对(老邮件全用「一」当破折号)才放开「一」,
        // 否则推荐文案里的"武汉一汉口"会抢走真实区间
        List<StationPair> strictPairs = stationPairMatches(text, STRICT_PAIR_PATTERN);
        List<StationPair> pairMatches = strictPairs.isEmpty() ? stationPairMatches(text, LOOSE_PAIR_PATTERN) : strictPairs;
        // 站名表没收录的站兜底:「XX站-YY站」形态按字面提取,不依赖站名表
        if (pairMatches.isEmpty()) pairMatches = literalStationPairMatches(text);

        List<Hit> stationHits = findStations(text);
        List<Hit> timeMatches = allMatches(TIME_PATTERN, text);
        List<OrderHit> orderHits = findOrderNos(text);

        Set<String> seen = new HashSet<>();
        List<ParsedTicket> tickets = new ArrayList<>();
        for (Hit tm : trainMatches) {
            int p = tm.start();
            String trainNo = normalizeTrainNo(tm.text());

            // 乘车人归属:车次号前面最近的编号项姓名;无编号项的单人邮件按姓名就近判断
            String segmentPassenger = null;
            for (PassengerItem item : passengerItems) {
                if (item.pos() < p) segmentPassenger = item.name();
            }
            if (owner != null && !owner.isEmpty()) {
                if (segmentPassenger != null) {
                    if (!segmentPassenger.equals(owner)) continue;
                } else if (passengerItems.isEmpty()) {
                    // "尊敬张三先生:"只是称呼,不算乘车人署名(代买邮件开头也是"尊敬XX先生")
                    boolean nearOwner = false;
                    for (Hit occ : allMatches(compile(Pattern.quote(owner)), text)) {
                        if (Math.abs(occ.start() - p) < 200 && !isSalutation(occ.start(), text)) {
                            nearOwner = true;
                            break;
                        }
                    }
                    if (!nearOwner) continue;
                } else {
                    continue;
                }
            }
            String passenger = segmentPassenger != null ? segmentPassenger : owner;

            // 站名:优先取"出发站-到达站"配对结构(离车次号最近的站对),退化为最近两个"不同名"站
            String fromStation = null;
            String toStation = null;
            StationPair bestPair = null;
            int bestPairDist = Integer.MAX_VALUE;
            for (StationPair pair : pairMatches) {
                int dist = Math.abs(pair.start() - p);
                if (bestPair == null || dist < bestPairDist) {
                    bestPair = pair;
                    bestPairDist = dist;
                }
            }
            if (bestPair != null) {
                fromStation = bestPair.from();
                toStation = bestPair.to();
            } else {
                // 只看车次 40 字内的站名,远处段落里的站名不能拿来当区间
                List<Hit> nearNames = new ArrayList<>();
                for (Hit hit : stationHits) {
                    if (Math.abs(hit.start() - p) <= 40) nearNames.add(hit);
                }
                nearNames.sort(Comparator.comparingInt(h -> Math.abs(h.start() - p)));
                List<String> uniqueNames = new ArrayList<>();
                for (Hit hit : nearNames) {
                    if (!uniqueNames.contains(hit.text())) uniqueNames.add(hit.text());
                }
                if (uniqueNames.size() >= 1) fromStation = uniqueNames.get(0);
                if (uniqueNames.size() >= 2) toStation = uniqueNames.get(1);
            }

            // 日期:取离车次号最近的日期(老邮件无年份时按发件时间推断)
            LocalDate rideDate = nearestDate(text, p, mailDate);

            // 时刻:最近的两个时间取字符串序较小者(开车时刻早于到达时刻)
            String departTimeText = null;
            List<Hit> nearestTimes = new ArrayList<>(timeMatches);
            nearestTimes.sort(Comparator.comparingInt(h -> Math.abs(h.start() - p)));
            if (nearestTimes.size() >= 2) {
                String t1 = nearestTimes.get(0).text();
                String t2 = nearestTimes.get(1).text();
                departTimeText = t1.compareTo(t2) <= 0 ? t1 : t2;
            } else if (nearestTimes.size() == 1) {
                departTimeText = nearestTimes.get(0).text();
            }

            // 席别:按词表顺序取正文中出现的第一个
            String seatClass = null;
            for (String sc : SEAT_CLASS_OPTIONS) {
                if (text.contains(sc)) {
                    seatClass = sc;
                    break;
                }
            }

            Double price = nearestPrice(text, p);
            String[] coachSeat = parseCoachSeat(text, p);
            String coach = coachSeat == null ? null : coachSeat[0];
            String seat = coachSeat == null ? null : coachSeat[1];
            // 订单号:离车次号最近的「订单号码」编号
            String orderNo = nearestOrderNo(orderHits, p);

            // 邮内去重:车次|站对 同 key 只留一条
            String key = nvl(trainNo) + "|" + nvl(fromStation) + "|" + nvl(toStation);
            if (!seen.add(key)) continue;
            // 同名站对无意义(多乘客邮件里同一站名出现多次导致),到达站留空给用户补
            if (fromStation != null && fromStation.equals(toStation)) toStation = null;
            tickets.add(new ParsedTicket(trainNo, fromStation, toStation, rideDate,
                    departTimeText, coach, seat, seatClass, price, passenger, orderNo));
        }
        List<ParsedTicket> result = new ArrayList<>();
        for (ParsedTicket t : tickets) {
            if (t.fromStation() != null || t.toStation() != null) result.add(t);
        }
        return result;
    }

    // ---- 组件 ----

    /** 一次正则命中(Java 用字符偏移替代 Swift 的 String.Index) */
    private record Hit(int start, int end, String text) {}

    private record StationPair(int start, String from, String to) {}

    /** 编号乘车人项("1.张三," -> 位置 + 姓名) */
    private record PassengerItem(int pos, String name) {}

    private record OrderHit(int start, String value) {}

    private static String nvl(String s) {
        return s == null ? "" : s;
    }

    /** Swift 的 allMatches:从左到右的全部非重叠命中 */
    private static List<Hit> allMatches(Pattern pattern, String text) {
        List<Hit> hits = new ArrayList<>();
        if (pattern == null) return hits;
        Matcher m = pattern.matcher(text);
        while (m.find()) {
            hits.add(new Hit(m.start(), m.end(), m.group()));
        }
        return hits;
    }

    /** 命中点前 3 字内是否落在"尊敬…先生/女士"这类称呼里 */
    private static boolean isSalutation(int start, String text) {
        int head = Math.max(0, start - 3);
        return text.substring(head, start).contains("尊敬");
    }

    private static List<PassengerItem> passengerItems(String text) {
        List<PassengerItem> items = new ArrayList<>();
        Matcher m = PASSENGER_ITEM_PATTERN.matcher(text);
        while (m.find()) {
            items.add(new PassengerItem(m.start(), m.group(1)));
        }
        return items;
    }

    private static String normalizeTrainNo(String s) {
        return s.toUpperCase(Locale.ROOT).replace(" ", "");
    }

    private static List<OrderHit> findOrderNos(String text) {
        List<OrderHit> hits = new ArrayList<>();
        Matcher m = ORDER_NO_PATTERN.matcher(text);
        while (m.find()) {
            if (m.group(1) != null) hits.add(new OrderHit(m.start(1), m.group(1)));
        }
        return hits;
    }

    private static String nearestOrderNo(List<OrderHit> hits, int pos) {
        String best = null;
        int bestDist = Integer.MAX_VALUE;
        for (OrderHit hit : hits) {
            int dist = Math.abs(hit.start() - pos);
            if (best == null || dist < bestDist) {
                best = hit.value();
                bestDist = dist;
            }
        }
        return best;
    }

    /** "郑州东站-开封站"/"杭州东至上海虹桥" 形态的站名对,两侧必须能解析为已知车站 */
    private static List<StationPair> stationPairMatches(String text, Pattern pattern) {
        List<StationPair> pairs = new ArrayList<>();
        if (pattern == null) return pairs;
        Matcher m = pattern.matcher(text);
        while (m.find()) {
            String rawFrom = m.group(1);
            String rawTo = m.group(2);
            if (rawFrom == null || rawTo == null) continue;
            String from = normalizeStation(rawFrom);
            String to = normalizeStation(rawTo);
            if (from.equals(to)) continue;
            if (isTruncated(rawFrom, m.end(1), text) || isTruncated(rawTo, m.end(2), text)) continue;
            pairs.add(new StationPair(m.start(), from, to));
        }
        return pairs;
    }

    private static List<StationPair> literalStationPairMatches(String text) {
        List<StationPair> pairs = new ArrayList<>();
        Matcher m = LITERAL_PAIR_PATTERN.matcher(text);
        while (m.find()) {
            String from = normalizeStation(m.group(1));
            String to = normalizeStation(m.group(2));
            if (from.equals(to)) continue;
            pairs.add(new StationPair(m.start(), from, to));
        }
        return pairs;
    }

    private static String normalizeStation(String s) {
        String name = s.strip();
        if (name.codePointCount(0, name.length()) > 2 && name.endsWith("站")) {
            name = name.substring(0, name.length() - 1);
        }
        return name;
    }

    /**
     * 命中是否是被截断的长站名:站名表缺「郑州西」时,alternation 会以「郑州」前缀命中「郑州西站」,
     * 把短名连同「站」吃掉留下「西」。命中文本向后扩 1-2 字若能拼出已知站,即视为截断命中,
     * 丢弃该站对,交给字面兜底/站名扫描按全名取。按代码点向后扩展,避免拆开代理对。
     */
    private static boolean isTruncated(String raw, int end, String text) {
        String base = raw;
        if (base.codePointCount(0, base.length()) > 2 && base.endsWith("站")) {
            base = base.substring(0, base.length() - 1);
        }
        String extended = base;
        int idx = end;
        for (int i = 0; i < 2; i++) {
            if (idx >= text.length()) break;
            int cp = text.codePointAt(idx);
            extended += new String(Character.toChars(cp));
            idx += Character.charCount(cp);
            if (Stations.stationNameSet().contains(extended)) return true;
        }
        return false;
    }

    /** 站名按长度降序拼接的站对大正则;站名表为空时返回 null */
    private static Pattern makePairPattern(String separators) {
        String alternation = stationAlternation();
        if (alternation == null) return null;
        return compile("((?:" + alternation + ")站?)\\s*[" + separators + "]{1,3}\\s*((?:" + alternation + ")站?)");
    }

    private static Pattern makeStationScanPattern() {
        String alternation = stationAlternation();
        return alternation == null ? null : compile(alternation);
    }

    private static String stationAlternation() {
        List<String> names = Stations.stationNamesByLengthDesc();
        if (names.isEmpty()) return null;
        StringBuilder sb = new StringBuilder();
        for (String name : names) {
            if (sb.length() > 0) sb.append('|');
            sb.append(Pattern.quote(name));
        }
        return sb.toString();
    }

    /** 站名词扫描:3400+ 站合并成一条 alternation 正则一次扫描;长名在前保证最长匹配 */
    private static List<Hit> findStations(String text) {
        return allMatches(STATION_SCAN_PATTERN, text);
    }

    private static LocalDate parseDate(String s) {
        Matcher m = DATE_PARTS_PATTERN.matcher(s);
        if (!m.find()) return null;
        try {
            return LocalDate.of(Integer.parseInt(m.group(1)), Integer.parseInt(m.group(2)), Integer.parseInt(m.group(3)));
        } catch (NumberFormatException | DateTimeException e) {
            // 非法日期(如 13 月 32 日)按无效处理,与 Calendar.date(from:) 返回 nil 一致
            return null;
        }
    }

    /** 乘车日期:取离车次号最近的日期。完整"2013年04月29日"直接解析;老邮件只写"04月29日"时按发件时间推断年份 */
    private static LocalDate nearestDate(String text, int pos, LocalDateTime mailDate) {
        List<Hit> full = allMatches(FULL_DATE_PATTERN, text);
        // 裸日期可能是完整日期的尾段("2013年04月11日"里的"04月11日"),排除重叠
        List<Hit> bare = new ArrayList<>();
        for (Hit b : allMatches(BARE_DATE_PATTERN, text)) {
            boolean overlaps = false;
            for (Hit f : full) {
                if (b.start() < f.end() && f.start() < b.end()) {
                    overlaps = true;
                    break;
                }
            }
            if (!overlaps) bare.add(b);
        }
        LocalDate best = null;
        int bestDist = Integer.MAX_VALUE;
        for (Hit hit : full) {
            LocalDate d = parseDate(hit.text());
            if (d == null) continue;
            int dist = Math.abs(hit.start() - pos);
            if (best == null || dist < bestDist) {
                best = d;
                bestDist = dist;
            }
        }
        for (Hit hit : bare) {
            LocalDate d = resolveMonthDay(hit.text(), mailDate);
            if (d == null) continue;
            int dist = Math.abs(hit.start() - pos);
            if (best == null || dist < bestDist) {
                best = d;
                bestDist = dist;
            }
        }
        return best;
    }

    /** "04月29日" → 年份取与发件时间最接近的那个:购票/改签邮件的乘车日期总在发件日附近 */
    private static LocalDate resolveMonthDay(String s, LocalDateTime mailDate) {
        Matcher m = MONTH_DAY_PATTERN.matcher(s);
        if (!m.find()) return null;
        int month;
        int day;
        try {
            month = Integer.parseInt(m.group(1));
            day = Integer.parseInt(m.group(2));
        } catch (NumberFormatException e) {
            return null;
        }
        ZoneId zone = ZoneId.systemDefault();
        LocalDateTime anchor = mailDate != null ? mailDate : LocalDateTime.now();
        long anchorMillis = anchor.atZone(zone).toInstant().toEpochMilli();
        int year = anchor.getYear();
        LocalDate best = null;
        long bestAbs = Long.MAX_VALUE;
        for (int y = year - 1; y <= year + 1; y++) {
            LocalDate d;
            try {
                d = LocalDate.of(y, month, day);
            } catch (DateTimeException e) {
                continue;
            }
            long abs = Math.abs(d.atStartOfDay(zone).toInstant().toEpochMilli() - anchorMillis);
            if (best == null || abs < bestAbs) {
                best = d;
                bestAbs = abs;
            }
        }
        return best;
    }

    /** 离车次号最近的价格(¥ 或 元 标记) */
    private static Double nearestPrice(String text, int pos) {
        Hit hit = nearest(allMatches(PRICE_PATTERN, text), pos);
        if (hit == null) return null;
        StringBuilder digits = new StringBuilder();
        for (int i = 0; i < hit.text().length(); ) {
            int cp = hit.text().codePointAt(i);
            if (Character.isDigit(cp) || cp == '.') digits.appendCodePoint(cp);
            i += Character.charCount(cp);
        }
        if (digits.length() == 0) return null;
        try {
            return Double.parseDouble(digits.toString());
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /** 距离最近的一次命中(并列时保留先出现者,与 Swift min(by:) 一致) */
    private static Hit nearest(List<Hit> hits, int pos) {
        Hit best = null;
        int bestDist = Integer.MAX_VALUE;
        for (Hit hit : hits) {
            int dist = Math.abs(hit.start() - pos);
            if (best == null || dist < bestDist) {
                best = hit;
                bestDist = dist;
            }
        }
        return best;
    }

    /** 就近识别 "05车04B号" 形态的车厢座位,返回 [车厢, 座位] */
    private static String[] parseCoachSeat(String text, int pos) {
        Hit hit = nearest(allMatches(COACH_SEAT_PATTERN, text), pos);
        if (hit == null) return null;
        Matcher m = COACH_SEAT_PATTERN.matcher(hit.text());
        if (m.find() && m.group(1) != null && m.group(2) != null) {
            return new String[] { m.group(1) + "车", m.group(2) };
        }
        return null;
    }
}

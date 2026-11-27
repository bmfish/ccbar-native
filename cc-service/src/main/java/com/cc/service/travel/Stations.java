package com.cc.service.travel;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

/**
 * 内置站名目录(classpath /travel/stations.json,3404 站):城市解析 + 里程估算。
 * 忠实移植自 iOS TravelNotes 的 Stations.swift(StationDirectory + MileageEstimator)。
 */
public final class Stations {

    private static final Logger log = LoggerFactory.getLogger(Stations.class);

    private Stations() {}

    private record Station(String name, String city, double lat, double lng) {}

    private static final Map<String, Station> BY_NAME = new HashMap<>();
    private static final Map<String, Station> BY_BASE = new HashMap<>();
    private static final Map<String, Station> BY_CITY = new HashMap<>();
    /** 站名按长度降序(长名在前),供解析器的 alternation 大正则使用 */
    private static final List<String> NAMES_BY_LENGTH_DESC = new ArrayList<>();
    private static final Set<String> NAME_SET = new HashSet<>();

    /** 常用线路的实际铁路里程(公里,城市对,键为排序后的"甲|乙")。数据来源:12306 票面里程与公开时刻表 */
    private static final Map<String, Double> RAIL_CITY_PAIRS = buildRailCityPairs();

    static {
        loadQuietly();
    }

    /** 静态初始化一次性加载;失败兜底按空表处理,不抛异常(解析器自动退到字面站对兜底) */
    private static void loadQuietly() {
        try (InputStream in = Stations.class.getResourceAsStream("/travel/stations.json")) {
            if (in == null) {
                log.warn("stations.json not found on classpath (/travel/stations.json), station tables stay empty");
                return;
            }
            JsonNode list = new ObjectMapper().readTree(in);
            if (list == null || !list.isArray()) {
                log.warn("stations.json is not a JSON array, station tables stay empty");
                return;
            }
            List<Station> parsed = new ArrayList<>();
            for (JsonNode node : list) {
                String name = node.path("n").asText(null);
                if (name == null || name.isEmpty()) continue;
                parsed.add(new Station(name, node.path("c").asText(""),
                        node.path("lat").asDouble(0.0), node.path("lng").asDouble(0.0)));
            }
            // Swift Dictionary(uniquingKeysWith: { a, _ in a }):重名保留先出现的
            for (Station s : parsed) {
                BY_NAME.putIfAbsent(s.name(), s);
                BY_BASE.putIfAbsent(strip(s.name()), s);
                BY_CITY.putIfAbsent(s.city(), s);
            }
            List<String> names = new ArrayList<>(parsed.stream().map(Station::name).distinct().toList());
            names.sort(String::compareTo);
            List<String> byLen = new ArrayList<>(names);
            // 长名在前;同长度时保持站名序,同一位置天然保留最长匹配(上海虹桥 优先于 上海)
            byLen.sort((a, b) -> Integer.compare(b.codePointCount(0, b.length()), a.codePointCount(0, a.length())));
            NAMES_BY_LENGTH_DESC.addAll(byLen);
            NAME_SET.addAll(names);
        } catch (Exception e) {
            log.warn("failed to load /travel/stations.json, station tables stay empty", e);
        }
    }

    /** "杭州东" -> "杭州",用于坐标匹配兜底;反复剥方向后缀(东/西/南/北/站),至少保留一字 */
    private static String strip(String name) {
        String s = name;
        while (s.length() > 1) {
            char last = s.charAt(s.length() - 1);
            if (last == '站' || last == '东' || last == '西' || last == '南' || last == '北') {
                s = s.substring(0, s.length() - 1);
            } else {
                break;
            }
        }
        return s;
    }

    /** 宽松匹配:全名 -> 去方向后缀 -> 城市名 */
    private static Station resolve(String raw) {
        if (raw == null) return null;
        String name = raw.strip();
        if (name.isEmpty()) return null;
        Station s = BY_NAME.get(name);
        if (s != null) return s;
        s = BY_BASE.get(strip(name));
        if (s != null) return s;
        return BY_CITY.get(name);
    }

    /**
     * 站名 -> 所属城市。null 安全;三级降级:全名 -> 去方向后缀(东/西/南/北/站) -> 城市名,
     * 查不到返回 null。如 "北京丰台" -> "北京","杭州东" -> "杭州"。
     */
    public static String resolveCity(String stationName) {
        Station s = resolve(stationName);
        return s == null ? null : s.city();
    }

    /**
     * 两站间铁路里程估算(公里):城市 pair 先查 railCityPairs 常量表,未收录线路按
     * Haversine 球面直线 × 1.25 估算;任一端无法解析或坐标为 (0,0) 占位时返回 0。
     */
    public static double kmBetween(String stationA, String stationB) {
        Station a = resolve(stationA);
        Station b = resolve(stationB);
        if (a == null || b == null) return 0;
        Double km = RAIL_CITY_PAIRS.get(cityKey(a.city(), b.city()));
        if (km != null) return km;
        // 站名表扩容后部分小站没有坐标(0,0 占位),按到(0,0)估会算出上万公里,宁缺毋滥返回 0
        if ((a.lat() == 0 && a.lng() == 0) || (b.lat() == 0 && b.lng() == 0)) return 0;
        double dLat = Math.toRadians(b.lat() - a.lat());
        double dLng = Math.toRadians(b.lng() - a.lng());
        double x = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                + Math.cos(Math.toRadians(a.lat())) * Math.cos(Math.toRadians(b.lat()))
                        * Math.sin(dLng / 2) * Math.sin(dLng / 2);
        double straight = 2 * 6371.0 * Math.asin(Math.min(1, Math.sqrt(x)));
        return straight * 1.25;
    }

    /**
     * 车次号 -> 车型描述:G/D/C/K/T/Z/L/Y/S/纯数字 -> 高速动车/动车/城际/快速/特快/直达/临客/市郊/普速,
     * 未知返回 "其他"。移植自 TicketEntry.swift 的 TrainKind.describe。
     */
    public static String trainCategory(String trainNo) {
        if (trainNo == null) return "其他";
        String no = trainNo.strip().toUpperCase(Locale.ROOT);
        if (no.isEmpty()) return "其他";
        switch (no.charAt(0)) {
            case 'G': return "高速动车";
            case 'D': return "动车";
            case 'C': return "城际";
            case 'K': return "快速";
            case 'T': return "特快";
            case 'Z': return "直达";
            case 'L':
            case 'Y': return "临客";
            case 'S': return "市郊";
            default: return isAllDigits(no) ? "普速" : "其他";
        }
    }

    private static boolean isAllDigits(String s) {
        for (int i = 0; i < s.length(); ) {
            int cp = s.codePointAt(i);
            if (!Character.isDigit(cp)) return false;
            i += Character.charCount(cp);
        }
        return true;
    }

    /** 城市 pair 的里程表键:两端站名排序后以 | 相连(方向无关) */
    private static String cityKey(String a, String b) {
        return a.compareTo(b) <= 0 ? a + "|" + b : b + "|" + a;
    }

    /** 20 条常用线路的实际铁路里程,照抄 Stations.swift 的 MileageEstimator.railCityPairs */
    private static Map<String, Double> buildRailCityPairs() {
        Object[][] raw = {
                {"上海", "郑州", 986.0}, {"上海", "开封", 1040.0}, {"上海", "阜阳", 648.0},
                {"上海", "北京", 1318.0}, {"上海", "杭州", 175.0}, {"上海", "苏州", 84.0},
                {"上海", "南京", 300.0}, {"上海", "合肥", 455.0}, {"上海", "武汉", 814.0},
                {"上海", "项城", 730.0}, {"上海", "洛阳", 1105.0}, {"上海", "麻城", 590.0},
                {"北京", "邯郸", 440.0}, {"郑州", "太原", 432.0}, {"郑州", "开封", 60.0},
                {"郑州", "淮阳", 170.0}, {"郑州", "阜阳", 213.0}, {"郑州", "洛阳", 118.0},
                {"阜阳", "淮阳", 55.0}, {"阜阳", "项城", 80.0},
        };
        Map<String, Double> map = new HashMap<>();
        for (Object[] row : raw) {
            map.put(cityKey((String) row[0], (String) row[1]), (Double) row[2]);
        }
        return map;
    }

    // ---- 供 TicketMailParser 使用的包内访问器(不属于 public API) ----

    /** 全部站名按长度降序(长名在前);站名表未加载时为空表 */
    static List<String> stationNamesByLengthDesc() {
        return NAMES_BY_LENGTH_DESC;
    }

    /** 全部站名集合,供解析器的长站名截断防护查询 */
    static Set<String> stationNameSet() {
        return NAME_SET;
    }
}

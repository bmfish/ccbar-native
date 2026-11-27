package com.cc.service.travel;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicInteger;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.cc.service.admin.AdminTimes;
import com.cc.service.push.PushService;
import com.fasterxml.jackson.databind.ObjectMapper;

/**
 * 旅行统计与票据管理接口（仅管理 Token / 管理员会话可访问）。
 * 统计口径：只计入状态 normal 的正式票根（退票/改签旧票不占旅程），与 iOS 端 StatsView 逻辑一致。
 */
@RestController
@RequestMapping("/api/admin/travel")
public class AdminTravelController {

    private static final Logger log = LoggerFactory.getLogger(AdminTravelController.class);

    /* ---------- 视图记录 ---------- */

    public record SyncView(
            String email,
            String owner,
            OffsetDateTime lastSyncAt,
            OffsetDateTime lastFullSyncAt,
            boolean running,
            boolean credentialsConfigured,
            long pendingCandidates,
            Map<String, Object> lastResult) {
    }

    public record Totals(
            long trips,
            long stations,
            long cities,
            double totalKm,
            double totalCost,
            long thisYearCount,
            long thisMonthCount) {
    }

    public record YearPoint(String year, long count) {
    }

    public record MonthPoint(String label, long count) {
    }

    public record HourPoint(String label, long count) {
    }

    public record RoutePoint(String route, long count, double km) {
    }

    public record CityPoint(String city, long count) {
    }

    public record Highlight(
            String rideDate,
            String trainNo,
            String fromStation,
            String toStation,
            double km,
            Double price) {
    }

    public record Highlights(Highlight latest, Highlight earliest, Highlight longest, Highlight priciest) {
    }

    public record OverviewResponse(
            OffsetDateTime now,
            SyncView sync,
            Totals totals,
            List<YearPoint> yearly,
            List<MonthPoint> monthly,
            List<HourPoint> hours,
            List<RoutePoint> topRoutes,
            List<CityPoint> topCities,
            Highlights highlights) {
    }

    public record TicketView(
            long id,
            LocalDate rideDate,
            String departTime,
            String trainNo,
            String fromStation,
            String toStation,
            String coach,
            String seat,
            String seatClass,
            Double price,
            String passenger,
            String status,
            String note,
            OffsetDateTime createdAt) {
    }

    public record TicketPageResponse(long total, int page, int size, List<TicketView> tickets) {
    }

    public record CandidateView(
            long id,
            String tripKey,
            LocalDate rideDate,
            String departTimeText,
            String trainNo,
            String fromStation,
            String toStation,
            String coach,
            String seat,
            String seatClass,
            Double price,
            String passenger,
            String orderNo,
            boolean imported,
            boolean dismissed,
            OffsetDateTime fetchedAt) {
    }

    public record CandidatesResponse(long total, long pending, List<CandidateView> candidates) {
    }

    public record ImportRequest(List<Long> ids) {
    }

    public record ImportResponse(int imported) {
    }

    public record SyncRequest(String mode) {
    }

    public record SyncResponse(boolean ok, String mode, boolean async, String message) {
    }

    public record StatusResponse(
            boolean running,
            String email,
            String owner,
            OffsetDateTime lastSyncAt,
            OffsetDateTime lastFullSyncAt,
            boolean credentialsConfigured,
            long pendingCandidates,
            Map<String, Object> lastResult) {
    }

    /* ---------- 实现 ---------- */

    private static final String[] HOUR_LABELS = {
            "00-03", "03-06", "06-09", "09-12", "12-15", "15-18", "18-21", "21-24"
    };

    private final TravelRepository repository;
    private final MailSyncEngine engine;
    private final ObjectMapper objectMapper;
    private final PushService pushService;
    private final ExecutorService syncExecutor;

    public AdminTravelController(TravelRepository repository, MailSyncEngine engine,
            ObjectMapper objectMapper, PushService pushService) {
        this.repository = repository;
        this.engine = engine;
        this.objectMapper = objectMapper;
        this.pushService = pushService;
        ThreadFactory factory = new ThreadFactory() {
            private final AtomicInteger seq = new AtomicInteger();

            @Override
            public Thread newThread(Runnable task) {
                Thread thread = new Thread(task, "travel-mail-sync-" + seq.incrementAndGet());
                thread.setDaemon(true);
                return thread;
            }
        };
        this.syncExecutor = Executors.newSingleThreadExecutor(factory);
    }

    @GetMapping("/overview")
    public OverviewResponse overview() {
        List<TravelRepository.TicketRow> all = repository.allTicketsForStats().stream()
                .filter(t -> "normal".equals(t.status()))
                .toList();

        double totalKm = 0;
        double totalCost = 0;
        Map<String, Long> stationSet = new LinkedHashMap<>();
        Map<String, Long> citySet = new LinkedHashMap<>();
        Map<String, Long> yearMap = new LinkedHashMap<>();
        Map<String, Long> monthMap = new LinkedHashMap<>();
        long[] hourBuckets = new long[8];
        Map<String, RouteAgg> routeMap = new LinkedHashMap<>();

        LocalDate today = LocalDate.now(AdminTimes.ZONE);
        String thisYear = String.valueOf(today.getYear());
        String thisMonth = "%04d-%02d".formatted(today.getYear(), today.getMonthValue());

        for (TravelRepository.TicketRow ticket : all) {
            double km = Stations.kmBetween(ticket.fromStation(), ticket.toStation());
            totalKm += km;
            if (ticket.price() != null) {
                totalCost += ticket.price().doubleValue();
            }
            countInto(stationSet, ticket.fromStation());
            countInto(stationSet, ticket.toStation());
            countInto(citySet, Stations.resolveCity(ticket.fromStation()));
            countInto(citySet, Stations.resolveCity(ticket.toStation()));
            if (ticket.rideDate() != null) {
                countInto(yearMap, String.valueOf(ticket.rideDate().getYear()));
                countInto(monthMap, "%04d-%02d".formatted(ticket.rideDate().getYear(),
                        ticket.rideDate().getMonthValue()));
            }
            int hour = departHour(ticket.departTime());
            if (hour >= 0) {
                hourBuckets[Math.min(hour / 3, 7)]++;
            }
            String route = normalizedRoute(ticket.fromStation(), ticket.toStation());
            if (route != null) {
                routeMap.computeIfAbsent(route, k -> new RouteAgg()).count++;
                routeMap.get(route).km += km;
            }
        }

        // 近 12 个月（旧→新），没有记录的月份补 0
        List<MonthPoint> monthly = new ArrayList<>();
        for (int i = 11; i >= 0; i--) {
            LocalDate month = today.minusMonths(i);
            String label = "%04d-%02d".formatted(month.getYear(), month.getMonthValue());
            monthly.add(new MonthPoint(label, monthMap.getOrDefault(label, 0L)));
        }

        List<Highlight> latest = new ArrayList<>();
        List<Highlight> earliest = new ArrayList<>();
        all.stream().max(Comparator.comparing(TravelRepository.TicketRow::rideDate))
                .ifPresent(t -> latest.add(toHighlight(t)));
        all.stream().min(Comparator.comparing(TravelRepository.TicketRow::rideDate))
                .ifPresent(t -> earliest.add(toHighlight(t)));

        Highlight longest = null;
        Highlight priciest = null;
        double maxKm = -1;
        double maxPrice = -1;
        for (TravelRepository.TicketRow ticket : all) {
            double km = Stations.kmBetween(ticket.fromStation(), ticket.toStation());
            if (km > maxKm) {
                maxKm = km;
                longest = toHighlight(ticket);
            }
            if (ticket.price() != null && ticket.price().doubleValue() > maxPrice) {
                maxPrice = ticket.price().doubleValue();
                priciest = toHighlight(ticket);
            }
        }

        List<YearPoint> yearly = yearMap.entrySet().stream()
                .sorted(Map.Entry.comparingByKey())
                .map(e -> new YearPoint(e.getKey(), e.getValue()))
                .toList();
        List<RoutePoint> topRoutes = routeMap.entrySet().stream()
                .sorted((a, b) -> Long.compare(b.getValue().count, a.getValue().count))
                .limit(5)
                .map(e -> new RoutePoint(e.getKey(), e.getValue().count, e.getValue().km))
                .toList();
        List<CityPoint> topCities = citySet.entrySet().stream()
                .sorted((a, b) -> Long.compare(b.getValue(), a.getValue()))
                .limit(5)
                .map(e -> new CityPoint(e.getKey(), e.getValue()))
                .toList();

        List<HourPoint> hours = new ArrayList<>();
        for (int i = 0; i < hourBuckets.length; i++) {
            hours.add(new HourPoint(HOUR_LABELS[i], hourBuckets[i]));
        }

        long trips = all.size();
        Totals totals = new Totals(trips, stationSet.size(), citySet.size(),
                Math.round(totalKm), Math.round(totalCost),
                yearMap.getOrDefault(thisYear, 0L), monthMap.getOrDefault(thisMonth, 0L));
        Highlights highlights = new Highlights(
                latest.isEmpty() ? null : latest.get(0),
                earliest.isEmpty() ? null : earliest.get(0),
                longest, priciest);
        return new OverviewResponse(AdminTimes.now(), syncView(), totals, yearly, monthly, hours,
                topRoutes, topCities, highlights);
    }

    @GetMapping("/tickets")
    public TicketPageResponse tickets(
            @RequestParam(required = false) String query,
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        int safeSize = Math.min(Math.max(size, 1), 200);
        int safePage = Math.max(page, 1);
        TravelRepository.TicketPage result = repository.listTickets(query, status, safePage, safeSize);
        List<TicketView> views = result.tickets().stream().map(this::toTicketView).toList();
        return new TicketPageResponse(result.total(), safePage, safeSize, views);
    }

    @GetMapping("/candidates")
    public CandidatesResponse candidates() {
        List<TravelRepository.CandidateRow> rows = repository.allCandidates();
        List<CandidateView> views = rows.stream().map(this::toCandidateView).toList();
        long pending = rows.stream().filter(r -> !r.imported() && !r.dismissed()).count();
        return new CandidatesResponse(rows.size(), pending, views);
    }

    @PostMapping("/candidates/import")
    public ResponseEntity<ImportResponse> importCandidates(@RequestBody ImportRequest request) {
        TravelRepository.ImportResult result =
                repository.importCandidates(request.ids() == null ? List.of() : request.ids());
        if (result.imported() > 0) {
            try {
                String preview = String.join("；", result.samples().subList(0,
                        Math.min(result.samples().size(), 3)));
                pushService.sendEventNotification("新票据",
                        "确认导入 " + result.imported() + " 张票根：" + preview, "旅行票据");
            } catch (Exception e) {
                log.warn("人工导入推送失败: {}", e.getMessage());
            }
        }
        return ResponseEntity.ok(new ImportResponse(result.imported()));
    }

    @PostMapping("/candidates/dismiss")
    public ImportResponse dismissCandidates(@RequestBody ImportRequest request) {
        int dismissed = repository.markCandidatesDismissed(request.ids() == null ? List.of() : request.ids());
        return new ImportResponse(dismissed);
    }

    /** 异步触发同步：全量可能拉取几千封邮件，统一后台执行，前端轮询 /sync/status。 */
    @PostMapping("/sync")
    public ResponseEntity<SyncResponse> sync(@RequestBody(required = false) SyncRequest request) {
        boolean full = request != null && "full".equalsIgnoreCase(request.mode());
        if (engine.isRunning()) {
            return ResponseEntity.status(409).body(new SyncResponse(false,
                    full ? "full" : "incremental", false, "同步已在进行中"));
        }
        if (!engine.credentialsConfigured()) {
            return ResponseEntity.badRequest().body(new SyncResponse(false,
                    full ? "full" : "incremental", false,
                    "未配置邮箱账号或授权码（TRAVEL_MAIL_EMAIL / TRAVEL_MAIL_AUTH_CODE）"));
        }
        syncExecutor.submit(() -> {
            try {
                engine.sync(full);
            } catch (Exception e) {
                log.error("12306 邮件同步失败: {}", e.getMessage());
            }
        });
        return ResponseEntity.ok(new SyncResponse(true, full ? "full" : "incremental", true,
                full ? "全量同步已启动，历史邮件较多，请稍候查看进度" : "同步已启动"));
    }

    @GetMapping("/sync/status")
    public StatusResponse status() {
        TravelRepository.SyncState state = repository.getSyncState();
        return new StatusResponse(engine.isRunning(), state.email(), state.owner(),
                state.lastSyncAt(), state.lastFullSyncAt(),
                engine.credentialsConfigured(), repository.countPendingCandidates(),
                parseResult(state.lastResult()));
    }

    /* ---------- 私有 ---------- */

    private static final class RouteAgg {
        long count;
        double km;
    }

    private SyncView syncView() {
        TravelRepository.SyncState state = repository.getSyncState();
        return new SyncView(state.email(), state.owner(), state.lastSyncAt(), state.lastFullSyncAt(),
                engine.isRunning(), engine.credentialsConfigured(),
                repository.countPendingCandidates(), parseResult(state.lastResult()));
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> parseResult(String json) {
        if (json == null || json.isBlank()) {
            return null;
        }
        try {
            return objectMapper.readValue(json, Map.class);
        } catch (Exception e) {
            return null;
        }
    }

    private static void countInto(Map<String, Long> map, String key) {
        if (key == null || key.isBlank()) {
            return;
        }
        map.merge(key, 1L, Long::sum);
    }

    private static int departHour(String departTime) {
        if (departTime == null || departTime.length() < 2) {
            return -1;
        }
        try {
            return Integer.parseInt(departTime.substring(0, 2));
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** 常走线路不分方向：站名排序后 "A ⇄ B"（对应 iOS 端逻辑）。 */
    private static String normalizedRoute(String from, String to) {
        if (from == null || to == null || from.isBlank() || to.isBlank()) {
            return null;
        }
        if (from.compareTo(to) <= 0) {
            return from + " ⇄ " + to;
        }
        return to + " ⇄ " + from;
    }

    private Highlight toHighlight(TravelRepository.TicketRow ticket) {
        return new Highlight(ticket.rideDate() == null ? null : ticket.rideDate().toString(),
                ticket.trainNo(), ticket.fromStation(), ticket.toStation(),
                Stations.kmBetween(ticket.fromStation(), ticket.toStation()),
                ticket.price() == null ? null : ticket.price().doubleValue());
    }

    private TicketView toTicketView(TravelRepository.TicketRow row) {
        return new TicketView(row.id(), row.rideDate(), row.departTime(), row.trainNo(),
                row.fromStation(), row.toStation(), row.coach(), row.seat(), row.seatClass(),
                row.price() == null ? null : row.price().doubleValue(), row.passenger(),
                row.status(), row.note(), row.createdAt());
    }

    private CandidateView toCandidateView(TravelRepository.CandidateRow row) {
        return new CandidateView(row.id(), row.tripKey(), row.rideDate(), row.departTimeText(),
                row.trainNo(), row.fromStation(), row.toStation(), row.coach(), row.seat(),
                row.seatClass(), row.price() == null ? null : row.price().doubleValue(),
                row.passenger(), row.orderNo(), row.imported(), row.dismissed(), row.fetchedAt());
    }
}

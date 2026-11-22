package com.cc.service.admin;

import java.lang.management.ManagementFactory;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** 概览、设备、系统状态与维护操作（仅管理 Token 可访问）。 */
@RestController
@RequestMapping("/api/admin")
public class AdminConsoleController {

    private static final DateTimeFormatter DAY_KEY = DateTimeFormatter.ofPattern("yyyy-MM-dd");
    private static final DateTimeFormatter DAY_LABEL = DateTimeFormatter.ofPattern("MM-dd");

    public record TrendSeries(String source, List<Long> data) {
    }

    public record Trend(List<String> days, List<String> labels, List<TrendSeries> series) {
    }

    public record ModelBar(String model, long tokens, double credits, double percent) {
    }

    public record HourlyUsage(
            List<String> labels,
            List<Long> tokens,
            List<Double> credits,
            List<Long> requests) {
    }

    public record TraeAccountView(
            long userId,
            String username,
            String account,
            Integer slot,
            double consumed,
            double total,
            double remaining,
            double todayCredits,
            OffsetDateTime updatedAt) {
    }

    public record TraeSummary(
            List<TraeAccountView> accounts,
            double totalRemaining,
            double totalQuota,
            double totalConsumed,
            OffsetDateTime updatedAt) {
    }

    public record RecentDeviceView(
            String deviceId,
            long userId,
            String username,
            OffsetDateTime firstSeenAt,
            OffsetDateTime lastSeenAt,
            boolean online) {
    }

    public record ServerInfo(
            String status,
            String db,
            String migration,
            long uptimeSeconds,
            OffsetDateTime startedAt,
            OffsetDateTime lastSyncAt,
            long todayActiveDevices) {
    }

    public record OverviewResponse(
            OffsetDateTime now,
            AdminConsoleRepository.OverviewKpi kpi,
            HourlyUsage hourly,
            TraeSummary trae,
            Trend trend,
            List<ModelBar> topModels,
            List<RecentDeviceView> recentDevices,
            ServerInfo server) {
    }

    public record DeviceSummary(long total, long online, long active24h, long offline7d) {
    }

    public record DeviceListRow(
            String deviceId,
            long userId,
            String username,
            OffsetDateTime firstSeenAt,
            OffsetDateTime lastSeenAt,
            boolean online,
            long eventCount) {
    }

    public record DevicesResponse(DeviceSummary summary, List<DeviceListRow> devices) {
    }

    public record SystemHealth(String status, String db, OffsetDateTime time) {
    }

    public record SystemResponse(
            String status,
            String db,
            String migration,
            long uptimeSeconds,
            OffsetDateTime startedAt,
            String version,
            AdminConsoleRepository.SystemCounts counts,
            OffsetDateTime lastUsageAt,
            OffsetDateTime lastDeviceSeenAt,
            SystemHealth health) {
    }

    public record PurgeResult(int deleted, int days) {
    }

    private final AdminConsoleRepository console;
    private final String version;

    public AdminConsoleController(
            AdminConsoleRepository console,
            @Value("${app.version:dev}") String version) {
        this.console = console;
        this.version = version;
    }

    @GetMapping("/overview")
    public OverviewResponse overview() {
        OffsetDateTime now = AdminTimes.now();
        OffsetDateTime todayStart = AdminTimes.startOfDay(now.toLocalDate());
        OffsetDateTime weekStart = AdminTimes.daysStart(7);
        OffsetDateTime onlineSince = now.minusMinutes(AdminTimes.ONLINE_MINUTES);

        AdminConsoleRepository.OverviewKpi kpi =
                console.overviewKpi(AdminTimes.thisWeekStart(), todayStart, now, onlineSince);

        HourlyUsage hourly = buildHourly(todayStart, now);
        TraeSummary trae = buildTrae(todayStart, now);
        Trend trend = buildTrend(weekStart, now);
        List<ModelBar> topModels = new ArrayList<>();
        for (AdminConsoleRepository.ModelAgg model : console.topModels(weekStart, now, 5)) {
            double percent = kpi.weekTokens() > 0
                    ? Math.round(model.tokens() * 1000.0 / kpi.weekTokens()) / 10.0
                    : 0;
            topModels.add(new ModelBar(model.model(), model.tokens(), model.credits(), percent));
        }

        List<RecentDeviceView> recentDevices = console.recentDevices(5).stream()
                .map(device -> new RecentDeviceView(
                        device.deviceId(),
                        device.userId(),
                        device.username(),
                        device.firstSeenAt(),
                        device.lastSeenAt(),
                        isOnline(device.lastSeenAt(), onlineSince)))
                .toList();

        long uptime = uptimeSeconds();
        OffsetDateTime lastSync = latest(console.lastDeviceSeen(), console.lastUsageUpdate());
        ServerInfo server = new ServerInfo(
                "UP",
                "UP",
                console.migrationVersion(),
                uptime,
                now.minusSeconds(uptime),
                lastSync,
                console.activeDevicesSince(todayStart));

        return new OverviewResponse(now, kpi, hourly, trae, trend, topModels, recentDevices, server);
    }

    @GetMapping("/devices")
    public DevicesResponse devices() {
        OffsetDateTime now = AdminTimes.now();
        OffsetDateTime onlineSince = now.minusMinutes(AdminTimes.ONLINE_MINUTES);
        OffsetDateTime dayAgo = now.minusHours(24);
        OffsetDateTime weekAgo = now.minusDays(7);

        List<DeviceListRow> devices = console.findAllDevices().stream()
                .map(device -> new DeviceListRow(
                        device.deviceId(),
                        device.userId(),
                        device.username(),
                        device.firstSeenAt(),
                        device.lastSeenAt(),
                        isOnline(device.lastSeenAt(), onlineSince),
                        device.eventCount()))
                .toList();

        long online = devices.stream().filter(DeviceListRow::online).count();
        long active24h = devices.stream()
                .filter(device -> device.lastSeenAt() != null && !device.lastSeenAt().isBefore(dayAgo))
                .count();
        long offline7d = devices.stream()
                .filter(device -> device.lastSeenAt() == null || device.lastSeenAt().isBefore(weekAgo))
                .count();

        return new DevicesResponse(
                new DeviceSummary(devices.size(), online, active24h, offline7d),
                devices);
    }

    @PostMapping("/devices/purge")
    public PurgeResult purgeDevices(@RequestParam(defaultValue = "7") int days) {
        int safeDays = Math.min(Math.max(days, 1), 365);
        int deleted = console.purgeDevicesBefore(AdminTimes.now().minusDays(safeDays));
        return new PurgeResult(deleted, safeDays);
    }

    @GetMapping("/system")
    public SystemResponse system() {
        OffsetDateTime now = AdminTimes.now();
        long uptime = uptimeSeconds();
        AdminConsoleRepository.SystemCounts counts = console.systemCounts();
        SystemHealth health = new SystemHealth("UP", "UP", now);
        return new SystemResponse(
                "UP",
                "UP",
                console.migrationVersion(),
                uptime,
                now.minusSeconds(uptime),
                version,
                counts,
                console.lastUsageUpdate(),
                console.lastDeviceSeen(),
                health);
    }

    @PostMapping("/maintenance/purge-usage")
    public PurgeResult purgeUsage(@RequestParam(defaultValue = "90") int days) {
        int safeDays = Math.min(Math.max(days, 1), 3650);
        long cutoff = AdminTimes.now().minusDays(safeDays).toEpochSecond();
        int deleted = console.purgeUsageBefore(cutoff);
        return new PurgeResult(deleted, safeDays);
    }

    private HourlyUsage buildHourly(OffsetDateTime from, OffsetDateTime to) {
        long[] tokens = new long[24];
        double[] credits = new double[24];
        long[] requests = new long[24];
        for (AdminConsoleRepository.HourUsage row : console.hourlyUsage(from, to)) {
            int hour = row.hour();
            if (hour < 0 || hour > 23) {
                continue;
            }
            tokens[hour] = row.tokens();
            credits[hour] = row.credits();
            requests[hour] = row.requests();
        }
        List<String> labels = new ArrayList<>(24);
        for (int hour = 0; hour < 24; hour++) {
            labels.add(String.valueOf(hour));
        }
        return new HourlyUsage(labels, boxed(tokens), boxed(credits), boxed(requests));
    }

    private TraeSummary buildTrae(OffsetDateTime todayStart, OffsetDateTime now) {
        List<TraeAccountView> accounts = new ArrayList<>();
        double totalRemaining = 0;
        double totalQuota = 0;
        double totalConsumed = 0;
        OffsetDateTime updatedAt = null;
        for (AdminConsoleRepository.TraeQuotaRow row
                : console.traeQuotas(todayStart.toEpochSecond(), now.toEpochSecond())) {
            double remaining = Math.max(0, row.total() - row.consumed());
            accounts.add(new TraeAccountView(
                    row.userId(),
                    row.username(),
                    row.account(),
                    row.slot(),
                    row.consumed(),
                    row.total(),
                    remaining,
                    row.todayCredits(),
                    row.updatedAt()));
            totalRemaining += remaining;
            totalQuota += row.total();
            totalConsumed += row.consumed();
            if (row.updatedAt() != null && (updatedAt == null || row.updatedAt().isAfter(updatedAt))) {
                updatedAt = row.updatedAt();
            }
        }
        return new TraeSummary(accounts, totalRemaining, totalQuota, totalConsumed, updatedAt);
    }

    private Trend buildTrend(OffsetDateTime from, OffsetDateTime to) {
        LocalDate today = to.toLocalDate();
        List<String> days = new ArrayList<>();
        List<String> labels = new ArrayList<>();
        for (int i = 6; i >= 0; i--) {
            LocalDate date = today.minusDays(i);
            days.add(date.format(DAY_KEY));
            labels.add(date.format(DAY_LABEL));
        }

        Map<String, long[]> bySource = new LinkedHashMap<>();
        for (AdminConsoleRepository.DaySourceCount row : console.trend(from, to)) {
            int index = days.indexOf(row.day());
            if (index < 0) {
                continue;
            }
            bySource.computeIfAbsent(row.source(), key -> new long[days.size()])[index] = row.events();
        }

        List<String> sources = new ArrayList<>(bySource.keySet());
        sources.sort((left, right) -> Long.compare(total(bySource.get(right)), total(bySource.get(left))));

        List<TrendSeries> series = sources.stream()
                .map(source -> new TrendSeries(source, boxed(bySource.get(source))))
                .toList();
        return new Trend(days, labels, series);
    }

    private static long total(long[] values) {
        long sum = 0;
        for (long value : values) {
            sum += value;
        }
        return sum;
    }

    private static List<Long> boxed(long[] values) {
        List<Long> result = new ArrayList<>(values.length);
        for (long value : values) {
            result.add(value);
        }
        return result;
    }

    private static List<Double> boxed(double[] values) {
        List<Double> result = new ArrayList<>(values.length);
        for (double value : values) {
            result.add(value);
        }
        return result;
    }

    private static long uptimeSeconds() {
        return ManagementFactory.getRuntimeMXBean().getUptime() / 1000;
    }

    private static OffsetDateTime latest(OffsetDateTime left, OffsetDateTime right) {
        if (left == null) {
            return right;
        }
        if (right == null) {
            return left;
        }
        return left.isAfter(right) ? left : right;
    }

    private static boolean isOnline(OffsetDateTime lastSeenAt, OffsetDateTime onlineSince) {
        return lastSeenAt != null && !lastSeenAt.isBefore(onlineSince);
    }
}

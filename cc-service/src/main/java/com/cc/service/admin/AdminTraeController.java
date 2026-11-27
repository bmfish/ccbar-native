package com.cc.service.admin;

import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Trae 账号余额、消耗趋势与上报健康（仅管理 Token 可访问）。 */
@RestController
@RequestMapping("/api/admin/trae")
public class AdminTraeController {

    private static final DateTimeFormatter DAY_KEY = DateTimeFormatter.ofPattern("yyyy-MM-dd");
    private static final DateTimeFormatter DAY_LABEL = DateTimeFormatter.ofPattern("MM-dd");
    private static final int MAX_DAYS = 90;
    private static final double LOW_BALANCE_RATIO = 0.10;
    private static final int STALE_HOURS = 24;

    public record TrendSeries(String account, String label, List<Double> data) {
    }

    public record Trend(String granularity, List<String> labels, List<TrendSeries> series) {
    }

    public record AccountView(
            long userId,
            String username,
            String account,
            String name,
            Integer slot,
            boolean hasQuota,
            double consumed,
            double total,
            double remaining,
            double percent,
            double todayCredits,
            double rangeCredits,
            double weekCredits,
            double monthCredits,
            double avgDaily,
            Double daysLeft,
            OffsetDateTime reportedAt,
            OffsetDateTime lastUsageAt,
            String status) {
    }

    public record Totals(
            double remaining,
            double quota,
            double consumed,
            double todayCredits,
            double rangeCredits,
            double avgDaily,
            Double daysLeft,
            int accounts,
            int billedAccounts,
            int activeToday,
            int alertCount) {
    }

    public record Alert(
            String severity,
            String type,
            String account,
            String label,
            Double percent,
            Double remaining,
            Double total,
            Double monthCredits,
            OffsetDateTime reportedAt,
            OffsetDateTime lastUsageAt) {
    }

    public record OverviewResponse(
            OffsetDateTime now,
            int days,
            Totals totals,
            List<AccountView> accounts,
            Trend trend,
            List<Alert> alerts) {
    }

    public record QuotaPoint(
            String date,
            double remaining,
            double total,
            double consumed,
            OffsetDateTime reportedAt) {
    }

    public record ModelUsage(String model, long events, long tokens, double credits) {
    }

    public record RecentUsage(
            OffsetDateTime at,
            String model,
            long tokens,
            double credits,
            long requests,
            String deviceId) {
    }

    public record DetailResponse(
            AccountView account,
            int days,
            List<String> labels,
            List<Double> dailyCredits,
            List<Long> dailyTokens,
            List<QuotaPoint> quotaHistory,
            List<ModelUsage> models,
            List<RecentUsage> recent) {
    }

    private final AdminConsoleRepository console;
    private final TtlCache<Integer, OverviewResponse> overviewCache = new TtlCache<>(30_000);

    public AdminTraeController(AdminConsoleRepository console) {
        this.console = console;
    }

    @GetMapping("/overview")
    public OverviewResponse overview(@RequestParam(defaultValue = "7") int days) {
        int safeDays = Math.min(Math.max(days, 1), MAX_DAYS);
        return overviewCache.get(safeDays, () -> buildOverview(safeDays));
    }

    private OverviewResponse buildOverview(int safeDays) {
        OffsetDateTime now = AdminTimes.now();
        OffsetDateTime todayStart = AdminTimes.startOfDay(now.toLocalDate());
        OffsetDateTime rangeStart = safeDays == 1 ? todayStart : todayStart.minusDays(safeDays - 1L);
        OffsetDateTime weekStart = todayStart.minusDays(6);
        OffsetDateTime monthStart = now.minusDays(30);
        OffsetDateTime since = monthStart.isBefore(rangeStart) ? monthStart : rangeStart;

        Map<String, AccountBuilder> merged = new LinkedHashMap<>();
        for (AdminConsoleRepository.TraeQuotaRow row
                : console.traeQuotas(todayStart.toEpochSecond(), now.toEpochSecond())) {
            AccountBuilder builder = new AccountBuilder(row.userId(), row.username(), row.account());
            builder.name = row.name();
            builder.slot = row.slot();
            builder.hasQuota = true;
            builder.consumed = row.consumed();
            builder.total = row.total();
            builder.todayCredits = row.todayCredits();
            builder.reportedAt = row.updatedAt();
            merged.put(key(row.userId(), row.account()), builder);
        }

        for (AdminConsoleRepository.TraeAccountUsageRow row : console.traeAccountUsage(
                since.toEpochSecond(), rangeStart.toEpochSecond(), weekStart.toEpochSecond(),
                todayStart.toEpochSecond(), monthStart.toEpochSecond(), now.toEpochSecond())) {
            String accountKey = key(row.userId(), row.account());
            AccountBuilder builder = merged.computeIfAbsent(accountKey, ignored -> {
                AccountBuilder created = new AccountBuilder(row.userId(), row.username(), row.account());
                created.name = "";
                return created;
            });
            builder.rangeCredits = row.rangeCredits();
            builder.weekCredits = row.weekCredits();
            builder.todayCredits = row.todayCredits();
            builder.monthCredits = row.monthCredits();
            builder.lastUsageAt = row.lastUsageAt();
        }

        List<AccountView> accounts = new ArrayList<>(merged.size());
        for (AccountBuilder builder : merged.values()) {
            accounts.add(toView(builder, now));
        }
        accounts.sort(Comparator.comparing(AccountView::hasQuota).reversed()
                .thenComparing(view -> view.slot() == null ? Integer.MAX_VALUE : view.slot())
                .thenComparing(AccountView::account));

        double totalRemaining = 0;
        double totalQuota = 0;
        double totalConsumed = 0;
        double totalToday = 0;
        double totalRange = 0;
        double totalWeek = 0;
        int billed = 0;
        int activeToday = 0;
        for (AccountView account : accounts) {
            if (account.hasQuota()) {
                totalRemaining += account.remaining();
                totalQuota += account.total();
                totalConsumed += account.consumed();
                if (account.total() > 0) {
                    billed++;
                }
            }
            totalToday += account.todayCredits();
            totalRange += account.rangeCredits();
            totalWeek += account.weekCredits();
            if (account.todayCredits() > 0) {
                activeToday++;
            }
        }
        double avgDaily = totalWeek / 7.0;
        Double daysLeft = totalQuota > 0 && avgDaily > 0 ? totalRemaining / avgDaily : null;

        List<Alert> alerts = buildAlerts(accounts);
        Trend trend = buildTrend(safeDays, rangeStart, now, accounts);
        Totals totals = new Totals(totalRemaining, totalQuota, totalConsumed, totalToday,
                totalRange, avgDaily, daysLeft, accounts.size(), billed, activeToday, alerts.size());
        return new OverviewResponse(now, safeDays, totals, accounts, trend, alerts);
    }

    @GetMapping("/account")
    public DetailResponse account(
            @RequestParam long userId,
            @RequestParam String account,
            @RequestParam(defaultValue = "30") int days) {
        int safeDays = Math.min(Math.max(days, 1), 90);
        String normalizedAccount = account == null ? "" : account.trim();
        OffsetDateTime now = AdminTimes.now();
        OffsetDateTime todayStart = AdminTimes.startOfDay(now.toLocalDate());
        OffsetDateTime rangeStart = safeDays == 1 ? todayStart : todayStart.minusDays(safeDays - 1L);
        OffsetDateTime weekStart = todayStart.minusDays(6);
        OffsetDateTime monthStart = now.minusDays(30);
        OffsetDateTime since = monthStart.isBefore(rangeStart) ? monthStart : rangeStart;

        AccountBuilder builder = null;
        for (AdminConsoleRepository.TraeQuotaRow row
                : console.traeQuotas(todayStart.toEpochSecond(), now.toEpochSecond())) {
            if (row.userId() == userId && row.account().equals(normalizedAccount)) {
                builder = quotaBuilder(row);
                break;
            }
        }
        for (AdminConsoleRepository.TraeAccountUsageRow row : console.traeAccountUsage(
                since.toEpochSecond(), rangeStart.toEpochSecond(), weekStart.toEpochSecond(),
                todayStart.toEpochSecond(), monthStart.toEpochSecond(), now.toEpochSecond())) {
            if (row.userId() != userId || !row.account().equals(normalizedAccount)) {
                continue;
            }
            if (builder == null) {
                builder = new AccountBuilder(row.userId(), row.username(), row.account());
                builder.name = "";
            }
            applyUsage(builder, row);
            break;
        }
        if (builder == null) {
            throw new org.springframework.web.server.ResponseStatusException(
                    org.springframework.http.HttpStatus.NOT_FOUND, "Trae 账号不存在");
        }
        AccountView view = toView(builder, now);

        List<String> keys = new ArrayList<>(safeDays);
        List<String> labels = new ArrayList<>(safeDays);
        LocalDate start = rangeStart.toLocalDate();
        for (int index = 0; index < safeDays; index++) {
            LocalDate date = start.plusDays(index);
            keys.add(date.toString());
            labels.add(date.format(DAY_LABEL));
        }
        long[] tokens = new long[safeDays];
        double[] credits = new double[safeDays];
        for (AdminConsoleRepository.TraeDayUsageRow row : console.traeAccountDailyUsage(
                userId, normalizedAccount, rangeStart.toEpochSecond(), now.toEpochSecond())) {
            int index = keys.indexOf(row.day());
            if (index < 0) {
                continue;
            }
            tokens[index] += row.tokens();
            credits[index] += row.credits();
        }
        List<Double> creditList = boxed(credits);
        List<Long> tokenList = boxedLong(tokens);

        List<QuotaPoint> quotaHistory = console.traeQuotaHistory(
                userId, normalizedAccount, rangeStart.toEpochSecond(), now.toEpochSecond()).stream()
                .map(row -> new QuotaPoint(
                        row.day(),
                        Math.max(0, row.total() - row.consumed()),
                        row.total(),
                        row.consumed(),
                        row.reportedAt()))
                .toList();
        List<ModelUsage> models = console.traeAccountModels(
                userId, normalizedAccount, rangeStart.toEpochSecond(), now.toEpochSecond(), 8).stream()
                .map(row -> new ModelUsage(row.model(), row.events(), row.tokens(), row.credits()))
                .toList();
        List<RecentUsage> recent = console.traeAccountRecentEvents(userId, normalizedAccount, 10).stream()
                .map(row -> new RecentUsage(
                        Instant.ofEpochSecond(row.createdAt()).atZone(AdminTimes.ZONE).toOffsetDateTime(),
                        row.model(),
                        row.inputTokens() + row.outputTokens() + row.cacheReadTokens()
                                + row.cacheCreationTokens(),
                        row.credits(),
                        row.requestCount(),
                        row.deviceId()))
                .toList();
        return new DetailResponse(view, safeDays, labels, creditList, tokenList, quotaHistory, models, recent);
    }

    private static AccountBuilder quotaBuilder(AdminConsoleRepository.TraeQuotaRow row) {
        AccountBuilder builder = new AccountBuilder(row.userId(), row.username(), row.account());
        builder.name = row.name();
        builder.slot = row.slot();
        builder.hasQuota = true;
        builder.consumed = row.consumed();
        builder.total = row.total();
        builder.todayCredits = row.todayCredits();
        builder.reportedAt = row.updatedAt();
        return builder;
    }

    private static void applyUsage(AccountBuilder builder,
            AdminConsoleRepository.TraeAccountUsageRow row) {
        builder.rangeCredits = row.rangeCredits();
        builder.weekCredits = row.weekCredits();
        builder.todayCredits = row.todayCredits();
        builder.monthCredits = row.monthCredits();
        builder.lastUsageAt = row.lastUsageAt();
    }

    private static AccountView toView(AccountBuilder builder, OffsetDateTime now) {
        double remaining = builder.hasQuota ? Math.max(0, builder.total - builder.consumed) : 0;
        double percent = builder.total > 0 ? builder.consumed * 100.0 / builder.total : 0;
        double avgDaily = builder.weekCredits / 7.0;
        Double daysLeft = builder.hasQuota && avgDaily > 0 ? remaining / avgDaily : null;
        return new AccountView(
                builder.userId,
                builder.username,
                builder.account,
                builder.name,
                builder.slot,
                builder.hasQuota,
                builder.consumed,
                builder.total,
                remaining,
                percent,
                builder.todayCredits,
                builder.rangeCredits,
                builder.weekCredits,
                builder.monthCredits,
                avgDaily,
                daysLeft,
                builder.reportedAt,
                builder.lastUsageAt,
                statusOf(builder, now));
    }

    private static List<Long> boxedLong(long[] values) {
        List<Long> result = new ArrayList<>(values.length);
        for (long value : values) {
            result.add(value);
        }
        return result;
    }

    private static String statusOf(AccountBuilder builder, OffsetDateTime now) {
        if (builder.total <= 0) {
            return builder.monthCredits > 0 || builder.weekCredits > 0 || builder.todayCredits > 0
                    ? "no_bill" : "no_data";
        }
        if ((builder.total - builder.consumed) / builder.total < LOW_BALANCE_RATIO) {
            return "low_balance";
        }
        if (builder.reportedAt == null || builder.reportedAt.isBefore(now.minusHours(STALE_HOURS))) {
            return "stale";
        }
        return "normal";
    }

    private static List<Alert> buildAlerts(List<AccountView> accounts) {
        List<Alert> alerts = new ArrayList<>();
        for (AccountView account : accounts) {
            String type = account.status();
            if (!"low_balance".equals(type) && !"no_bill".equals(type) && !"stale".equals(type)) {
                continue;
            }
            alerts.add(new Alert(
                    "stale".equals(type) ? "bad" : "warn",
                    type,
                    account.account(),
                    labelOf(account),
                    account.percent(),
                    account.remaining(),
                    account.total(),
                    account.monthCredits(),
                    account.reportedAt(),
                    account.lastUsageAt()));
        }
        alerts.sort(Comparator.comparing((Alert alert) -> "bad".equals(alert.severity()) ? 0 : 1)
                .thenComparing(Alert::label));
        return alerts;
    }

    private Trend buildTrend(int days, OffsetDateTime rangeStart, OffsetDateTime to,
            List<AccountView> accounts) {
        Map<String, AccountView> byKey = new HashMap<>();
        for (AccountView account : accounts) {
            byKey.put(key(account.userId(), account.account()), account);
        }

        if (days == 1) {
            List<String> labels = new ArrayList<>(24);
            for (int hour = 0; hour < 24; hour++) {
                labels.add(String.valueOf(hour));
            }
            Map<String, double[]> values = new LinkedHashMap<>();
            for (AdminConsoleRepository.TraeHourAccountRow row
                    : console.traeHourlyByAccount(rangeStart.toEpochSecond(), to.toEpochSecond())) {
                if (row.hour() < 0 || row.hour() > 23) {
                    continue;
                }
                values.computeIfAbsent(key(row.userId(), row.account()), ignored -> new double[24])[row.hour()]
                        += row.credits();
            }
            return new Trend("hour", labels, toSeries(values, byKey));
        }

        List<String> keys = new ArrayList<>(days);
        List<String> labels = new ArrayList<>(days);
        LocalDate start = rangeStart.toLocalDate();
        for (int index = 0; index < days; index++) {
            LocalDate date = start.plusDays(index);
            keys.add(date.format(DAY_KEY));
            labels.add(date.format(DAY_LABEL));
        }
        Map<String, double[]> values = new LinkedHashMap<>();
        for (AdminConsoleRepository.TraeDailyAccountRow row
                : console.traeDailyByAccount(rangeStart.toEpochSecond(), to.toEpochSecond())) {
            int index = keys.indexOf(row.day());
            if (index < 0) {
                continue;
            }
            values.computeIfAbsent(key(row.userId(), row.account()), ignored -> new double[days])[index]
                    += row.credits();
        }
        return new Trend("day", labels, toSeries(values, byKey));
    }

    private static List<TrendSeries> toSeries(Map<String, double[]> values,
            Map<String, AccountView> accounts) {
        List<TrendSeries> series = new ArrayList<>(values.size());
        for (Map.Entry<String, double[]> entry : values.entrySet()) {
            double total = 0;
            for (double value : entry.getValue()) {
                total += value;
            }
            if (total <= 0) {
                continue;
            }
            AccountView account = accounts.get(entry.getKey());
            String label = account != null ? labelOf(account) : "Trae " + shortAccount(accountPart(entry.getKey()));
            series.add(new TrendSeries(entry.getKey(), label, boxed(entry.getValue())));
        }
        series.sort((left, right) -> Double.compare(sum(right.data()), sum(left.data())));
        return series;
    }

    private static double sum(List<Double> values) {
        double total = 0;
        for (double value : values) {
            total += value;
        }
        return total;
    }

    private static List<Double> boxed(double[] values) {
        List<Double> result = new ArrayList<>(values.length);
        for (double value : values) {
            result.add(value);
        }
        return result;
    }

    private static String labelOf(AccountView account) {
        if (account.name() != null && !account.name().isBlank()) {
            return account.name();
        }
        if (account.slot() != null) {
            return "Trae " + account.slot();
        }
        return "Trae " + shortAccount(account.account());
    }

    private static String shortAccount(String account) {
        if (account == null) {
            return "";
        }
        return account.length() > 10
                ? account.substring(0, 4) + "…" + account.substring(account.length() - 4)
                : account;
    }

    private static String key(long userId, String account) {
        return userId + "\u0000" + (account == null ? "" : account);
    }

    private static String accountPart(String key) {
        int index = key.indexOf('\u0000');
        return index < 0 ? key : key.substring(index + 1);
    }

    private static final class AccountBuilder {
        private final long userId;
        private final String username;
        private final String account;
        private String name = "";
        private Integer slot;
        private boolean hasQuota;
        private double consumed;
        private double total;
        private double todayCredits;
        private double rangeCredits;
        private double weekCredits;
        private double monthCredits;
        private OffsetDateTime reportedAt;
        private OffsetDateTime lastUsageAt;

        private AccountBuilder(long userId, String username, String account) {
            this.userId = userId;
            this.username = username;
            this.account = account == null ? "" : account;
        }
    }
}

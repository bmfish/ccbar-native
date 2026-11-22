package com.cc.service.admin;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.cc.service.auth.UserRepository;

/** 用量分析、流水聚合与 CSV 导出（仅管理 Token 可访问）。 */
@RestController
@RequestMapping("/api/admin/usage")
public class AdminUsageController {

    private static final DateTimeFormatter CLOCK = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private static final int MAX_EXPORT = 5000;

    public record UserOption(long id, String username) {
    }

    public record Options(List<String> sources, List<String> models, List<UserOption> users) {
    }

    public record UsageRowView(
            OffsetDateTime at,
            long userId,
            String username,
            String source,
            String appType,
            String model,
            long inputTokens,
            long outputTokens,
            long cacheReadTokens,
            long cacheCreationTokens,
            long reasoningTokens,
            long tokens,
            double totalCostUsd,
            double credits,
            long requestCount,
            String account,
            String deviceId) {
    }

    public record SummaryResponse(
            OffsetDateTime from,
            OffsetDateTime to,
            AdminConsoleRepository.UsageTotals totals,
            List<AdminConsoleRepository.SourceAgg> bySource,
            List<AdminConsoleRepository.ModelAgg> byModel,
            List<UsageRowView> recent) {
    }

    public record FlowBucket(
            long fromEpoch,
            long toEpoch,
            long events,
            long requests,
            long tokens,
            double credits,
            double percent) {
    }

    public record FlowResponse(
            OffsetDateTime from,
            OffsetDateTime to,
            String granularity,
            AdminConsoleRepository.UsageTotals totals,
            List<FlowBucket> buckets) {
    }

    public record BucketItemsResponse(long total, int limit, List<UsageRowView> items) {
    }

    private final AdminConsoleRepository console;
    private final UserRepository users;

    public AdminUsageController(AdminConsoleRepository console, UserRepository users) {
        this.console = console;
        this.users = users;
    }

    @GetMapping("/options")
    public Options options() {
        List<UserOption> userOptions = users.findAll().stream()
                .map(user -> new UserOption(user.id(), user.username()))
                .toList();
        return new Options(console.distinctSources(), console.distinctModels(), userOptions);
    }

    @GetMapping("/summary")
    public SummaryResponse summary(
            @RequestParam(defaultValue = "7") int days,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime to,
            @RequestParam(required = false) Long userId,
            @RequestParam(required = false) String source,
            @RequestParam(required = false) String model) {
        Range range = resolve(days, from, to);
        AdminConsoleRepository.UsageTotals totals =
                console.usageTotals(range.fromEpoch(), range.toEpoch(), userId, source, model);
        List<AdminConsoleRepository.SourceAgg> bySource =
                console.usageBySource(range.fromEpoch(), range.toEpoch(), userId, source, model);
        List<AdminConsoleRepository.ModelAgg> byModel =
                console.usageByModel(range.fromEpoch(), range.toEpoch(), userId, source, model, 8);
        List<UsageRowView> recent = console.recentEvents(range.fromEpoch(), range.toEpoch(),
                        userId, source, model, 5).stream()
                .map(this::toView)
                .toList();
        return new SummaryResponse(range.from(), range.to(), totals, bySource, byModel, recent);
    }

    @GetMapping("/flow")
    public FlowResponse flow(
            @RequestParam(defaultValue = "1") int days,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime to,
            @RequestParam(required = false) Long userId,
            @RequestParam(required = false) String source,
            @RequestParam(required = false) String model) {
        Range range = resolve(days, from, to);
        AdminConsoleRepository.UsageTotals totals =
                console.usageTotals(range.fromEpoch(), range.toEpoch(), userId, source, model);
        List<AdminConsoleRepository.HourBucket> hours =
                console.flowHourly(range.fromEpoch(), range.toEpoch(), userId, source, model);

        boolean hourly = Duration.between(range.from(), range.to()).toHours() <= 48;
        List<FlowBucket> buckets = hourly
                ? hourlyBuckets(hours, totals.credits())
                : dailyBuckets(hours, totals.credits());
        return new FlowResponse(range.from(), range.to(), hourly ? "hour" : "day", totals, buckets);
    }

    @GetMapping("/bucket-items")
    public BucketItemsResponse bucketItems(
            @RequestParam long from,
            @RequestParam long to,
            @RequestParam(required = false) Long userId,
            @RequestParam(required = false) String source,
            @RequestParam(required = false) String model,
            @RequestParam(defaultValue = "100") int limit) {
        int safeLimit = Math.min(Math.max(limit, 1), 500);
        long total = console.countEvents(from, to, userId, source, model);
        List<UsageRowView> items = console.recentEvents(from, to, userId, source, model, safeLimit)
                .stream()
                .map(this::toView)
                .toList();
        return new BucketItemsResponse(total, safeLimit, items);
    }

    @GetMapping(value = "/export", produces = "text/csv;charset=UTF-8")
    public ResponseEntity<byte[]> export(
            @RequestParam(defaultValue = "7") int days,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime to,
            @RequestParam(required = false) Long userId,
            @RequestParam(required = false) String source,
            @RequestParam(required = false) String model) {
        Range range = resolve(days, from, to);
        List<AdminConsoleRepository.UsageRow> rows =
                console.recentEvents(range.fromEpoch(), range.toEpoch(), userId, source, model, MAX_EXPORT);

        StringBuilder csv = new StringBuilder("\uFEFF");
        csv.append("时间,用户,来源,应用,模型,输入Token,输出Token,缓存读取,缓存写入,推理Token,积分,金额USD,请求数,设备ID,账号\n");
        for (AdminConsoleRepository.UsageRow row : rows) {
            csv.append(csvCell(CLOCK.format(Instant.ofEpochSecond(row.createdAt()).atZone(AdminTimes.ZONE))))
                    .append(',').append(csvCell(row.username()))
                    .append(',').append(csvCell(row.source()))
                    .append(',').append(csvCell(row.appType()))
                    .append(',').append(csvCell(row.model()))
                    .append(',').append(row.inputTokens())
                    .append(',').append(row.outputTokens())
                    .append(',').append(row.cacheReadTokens())
                    .append(',').append(row.cacheCreationTokens())
                    .append(',').append(row.reasoningTokens())
                    .append(',').append(decimal(row.credits(), 2))
                    .append(',').append(decimal(row.totalCostUsd(), 4))
                    .append(',').append(row.requestCount())
                    .append(',').append(csvCell(row.deviceId()))
                    .append(',').append(csvCell(row.account()))
                    .append('\n');
        }

        String filename = "usage-" + LocalDate.now(AdminTimes.ZONE) + ".csv";
        return ResponseEntity.ok()
                .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"" + filename + "\"")
                .contentType(MediaType.parseMediaType("text/csv;charset=UTF-8"))
                .body(csv.toString().getBytes(StandardCharsets.UTF_8));
    }

    private List<FlowBucket> hourlyBuckets(List<AdminConsoleRepository.HourBucket> hours, double totalCredits) {
        List<FlowBucket> buckets = new ArrayList<>(hours.size());
        for (AdminConsoleRepository.HourBucket hour : hours) {
            buckets.add(new FlowBucket(
                    hour.bucketEpoch(),
                    hour.bucketEpoch() + 3600,
                    hour.events(),
                    hour.requests(),
                    hour.tokens(),
                    hour.credits(),
                    percent(hour.credits(), totalCredits)));
        }
        return buckets;
    }

    private List<FlowBucket> dailyBuckets(List<AdminConsoleRepository.HourBucket> hours, double totalCredits) {
        Map<LocalDate, FlowBucket> byDay = new TreeMap<>();
        for (AdminConsoleRepository.HourBucket hour : hours) {
            LocalDate day = Instant.ofEpochSecond(hour.bucketEpoch())
                    .atZone(AdminTimes.ZONE).toLocalDate();
            long dayStart = AdminTimes.startOfDay(day).toEpochSecond();
            FlowBucket current = byDay.get(day);
            if (current == null) {
                byDay.put(day, new FlowBucket(dayStart, dayStart + 86400, hour.events(), hour.requests(),
                        hour.tokens(), hour.credits(), 0));
            } else {
                byDay.put(day, new FlowBucket(dayStart, dayStart + 86400,
                        current.events() + hour.events(),
                        current.requests() + hour.requests(),
                        current.tokens() + hour.tokens(),
                        current.credits() + hour.credits(),
                        0));
            }
        }
        List<FlowBucket> buckets = new ArrayList<>(byDay.size());
        for (FlowBucket bucket : byDay.values()) {
            buckets.add(new FlowBucket(bucket.fromEpoch(), bucket.toEpoch(), bucket.events(),
                    bucket.requests(), bucket.tokens(), bucket.credits(),
                    percent(bucket.credits(), totalCredits)));
        }
        return buckets;
    }

    private UsageRowView toView(AdminConsoleRepository.UsageRow row) {
        long tokens = row.inputTokens() + row.outputTokens()
                + row.cacheReadTokens() + row.cacheCreationTokens();
        return new UsageRowView(
                Instant.ofEpochSecond(row.createdAt()).atZone(AdminTimes.ZONE).toOffsetDateTime(),
                row.userId(),
                row.username(),
                row.source(),
                row.appType(),
                row.model(),
                row.inputTokens(),
                row.outputTokens(),
                row.cacheReadTokens(),
                row.cacheCreationTokens(),
                row.reasoningTokens(),
                tokens,
                row.totalCostUsd(),
                row.credits(),
                row.requestCount(),
                row.account(),
                row.deviceId());
    }

    private Range resolve(int days, OffsetDateTime from, OffsetDateTime to) {
        OffsetDateTime end = to != null ? to : AdminTimes.now();
        int safeDays = Math.min(Math.max(days, 1), 3650);
        OffsetDateTime start = from != null
                ? from
                : AdminTimes.startOfDay(end.toLocalDate()).minusDays(safeDays - 1L);
        if (!start.isBefore(end)) {
            throw new IllegalArgumentException("时间范围不合法");
        }
        return new Range(start, end);
    }

    private static double percent(double value, double total) {
        if (total <= 0) {
            return 0;
        }
        return Math.round(value * 1000.0 / total) / 10.0;
    }

    private static String csvCell(String value) {
        String text = value == null ? "" : value;
        return "\"" + text.replace("\"", "\"\"") + "\"";
    }

    private static String decimal(double value, int scale) {
        return BigDecimal.valueOf(value)
                .setScale(scale, RoundingMode.HALF_UP)
                .stripTrailingZeros()
                .toPlainString();
    }

    private record Range(OffsetDateTime from, OffsetDateTime to) {
        long fromEpoch() {
            return from.toEpochSecond();
        }

        long toEpoch() {
            return to.toEpochSecond();
        }
    }
}

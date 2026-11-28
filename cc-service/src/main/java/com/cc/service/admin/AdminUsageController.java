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
import java.util.LinkedHashMap;
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
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

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

    public record DailySeries(String source, List<Long> tokens, List<Double> credits) {
    }

    public record DailyResponse(
            OffsetDateTime from,
            OffsetDateTime to,
            List<String> labels,
            List<DailySeries> series) {
    }

    private final AdminConsoleRepository console;
    private final UserRepository users;
    private final AiAnalysisService aiAnalysis;
    private final ObjectMapper objectMapper;

    public AdminUsageController(AdminConsoleRepository console, UserRepository users,
                                AiAnalysisService aiAnalysis, ObjectMapper objectMapper) {
        this.console = console;
        this.users = users;
        this.aiAnalysis = aiAnalysis;
        this.objectMapper = objectMapper;
    }

    /* ---------- AI 分析 ---------- */

    private static final String DOMAIN_USAGE = "usage";

    private static final String AI_USAGE_SYSTEM_PROMPT = """
            你是用量数据分析师，分析 AI CLI 编程工具（cc-switch / ZCode / Trae 等来源）的 token 与积分消耗。只输出一个 JSON 对象，不要输出任何其它文字或 markdown 代码块。字段定义：
            summary：两三句话总结消耗总量与趋势；
            trend：对象，含 daily 数组（每项含 day、tokens、credits）和 pace（一句话节奏评价）；
            anomalies：数组，每项含 date 与 reason（消耗突增突降、整天无同步、单日异常高等，没有则空数组）；
            suggestions：数组，2~3 条省钱或使用调度建议。
            """;

    public record AiUsageResponse(
            boolean cached, boolean stale, boolean available,
            String model, OffsetDateTime analyzedAt, JsonNode analysis) {
    }

    /** 用量 AI 分析：按数据指纹缓存，无新增上报时直接复用上次结果，不调用 LLM。 */
    @GetMapping("/ai-analysis")
    public AiUsageResponse aiAnalysis(
            @RequestParam(defaultValue = "7") int days,
            @RequestParam(defaultValue = "false") boolean refresh,
            @RequestParam(defaultValue = "false") boolean cachedOnly) {
        int safeDays = Math.min(Math.max(days, 1), 365);
        String fingerprint = console.usageFingerprint();

        if (cachedOnly) {
            return aiAnalysis.findCached(DOMAIN_USAGE, fingerprint, safeDays)
                    .map(r -> new AiUsageResponse(true, r.stale(), true, r.model(), r.analyzedAt(), r.analysis()))
                    .orElseGet(() -> new AiUsageResponse(false, false, false, null, null, null));
        }

        OffsetDateTime end = AdminTimes.now();
        OffsetDateTime start = AdminTimes.daysStart(safeDays);
        long fromEpoch = start.toEpochSecond();
        long toEpoch = end.toEpochSecond();

        var totals = console.usageTotals(fromEpoch, toEpoch, null, "", "");
        List<AdminConsoleRepository.SourceAgg> bySource = console.usageBySource(fromEpoch, toEpoch, null, "", "");
        List<AdminConsoleRepository.ModelAgg> byModel = console.usageByModel(fromEpoch, toEpoch, null, "", "", 8);
        List<Map<String, Object>> daily = dailyTotals(console.usageDailyBySource(fromEpoch, toEpoch, null, "", ""));

        AiAnalysisService.AiResult result = aiAnalysis.analyze(DOMAIN_USAGE, fingerprint, safeDays,
                AI_USAGE_SYSTEM_PROMPT,
                buildUsagePrompt(safeDays, start, end, totals, bySource, byModel, daily), refresh);
        return new AiUsageResponse(result.cached(), result.stale(), true, result.model(), result.analyzedAt(), result.analysis());
    }

    /** 把 天×来源 明细合并成每日总量（tokens + 积分）。 */
    private List<Map<String, Object>> dailyTotals(List<AdminConsoleRepository.DaySourceUsageRow> rows) {
        Map<String, long[]> tokensByDay = new LinkedHashMap<>();
        Map<String, double[]> creditsByDay = new LinkedHashMap<>();
        for (AdminConsoleRepository.DaySourceUsageRow row : rows) {
            tokensByDay.computeIfAbsent(row.day(), k -> new long[1])[0] += row.tokens();
            creditsByDay.computeIfAbsent(row.day(), k -> new double[1])[0] += row.credits();
        }
        return tokensByDay.entrySet().stream()
                .sorted(Map.Entry.comparingByKey())
                .map(e -> Map.<String, Object>of(
                        "day", e.getKey(),
                        "tokens", e.getValue()[0],
                        "credits", Math.round(creditsByDay.get(e.getKey())[0] * 10.0) / 10.0))
                .toList();
    }

    private String buildUsagePrompt(int days, OffsetDateTime start, OffsetDateTime end,
                                    AdminConsoleRepository.UsageTotals totals,
                                    List<AdminConsoleRepository.SourceAgg> bySource,
                                    List<AdminConsoleRepository.ModelAgg> byModel,
                                    List<Map<String, Object>> daily) {
        StringBuilder prompt = new StringBuilder();
        prompt.append("分析最近 ").append(days).append(" 天（").append(start.toLocalDate()).append(" 至 ")
                .append(end.toLocalDate()).append("）的 AI CLI 用量数据。\n");
        prompt.append("总量：事件 ").append(totals.events()).append("，请求 ").append(totals.requests())
                .append("，tokens ").append(totals.tokens())
                .append("（缓存读 ").append(totals.cacheReadTokens()).append("，缓存写 ").append(totals.cacheCreationTokens())
                .append("），积分 ").append(totals.credits())
                .append("，费用 $").append(totals.costUsd())
                .append("，活跃设备 ").append(totals.devices()).append("。\n");
        prompt.append("按来源：").append(toJson(bySource)).append("\n");
        prompt.append("按模型 TOP8：").append(toJson(byModel)).append("\n");
        prompt.append("每日汇总：").append(toJson(daily)).append("\n");
        return prompt.toString();
    }

    private String toJson(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("分析输入序列化失败", exception);
        }
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

    @GetMapping("/daily")
    public DailyResponse daily(
            @RequestParam(defaultValue = "7") int days,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime to,
            @RequestParam(required = false) Long userId,
            @RequestParam(required = false) String source,
            @RequestParam(required = false) String model) {
        Range range = resolve(days, from, to);
        List<String> keys = new ArrayList<>();
        List<String> labels = new ArrayList<>();
        LocalDate start = range.from().toLocalDate();
        LocalDate end = range.to().toLocalDate();
        for (LocalDate date = start; !date.isAfter(end); date = date.plusDays(1)) {
            keys.add(date.toString());
            labels.add(date.format(DateTimeFormatter.ofPattern("MM-dd")));
        }

        Map<String, long[]> tokens = new LinkedHashMap<>();
        Map<String, double[]> credits = new LinkedHashMap<>();
        for (AdminConsoleRepository.DaySourceUsageRow row : console.usageDailyBySource(
                range.fromEpoch(), range.toEpoch(), userId, source, model)) {
            int index = keys.indexOf(row.day());
            if (index < 0) {
                continue;
            }
            tokens.computeIfAbsent(row.source(), ignored -> new long[keys.size()])[index] += row.tokens();
            credits.computeIfAbsent(row.source(), ignored -> new double[keys.size()])[index] += row.credits();
        }

        List<DailySeries> series = new ArrayList<>();
        for (Map.Entry<String, long[]> entry : tokens.entrySet()) {
            List<Long> tokenValues = new ArrayList<>(entry.getValue().length);
            for (long value : entry.getValue()) {
                tokenValues.add(value);
            }
            double[] creditValues = credits.getOrDefault(entry.getKey(), new double[keys.size()]);
            List<Double> creditList = new ArrayList<>(creditValues.length);
            for (double value : creditValues) {
                creditList.add(value);
            }
            series.add(new DailySeries(entry.getKey(), tokenValues, creditList));
        }
        series.sort((left, right) -> Double.compare(sum(right.credits()), sum(left.credits())));
        return new DailyResponse(range.from(), range.to(), labels, series);
    }

    private static double sum(List<Double> values) {
        double total = 0;
        for (double value : values) {
            total += value;
        }
        return total;
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

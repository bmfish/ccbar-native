package com.cc.service.admin;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Comparator;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import com.cc.service.health.HealthSample;
import com.cc.service.health.HealthSampleRepository;
import com.cc.service.llm.LlmClient;
import com.cc.service.settings.AppSettings;

/** 健康数据汇总与 AI 分析（仅管理 Token 可访问）。 */
@RestController
@RequestMapping("/api/admin/health")
public class AdminHealthController {

    public record HealthLatest(String kind, double value, OffsetDateTime recordedAt, String source) {
    }

    public record WeightPoint(String date, double value) {
    }

    public record HealthRecordView(String kind, double value, OffsetDateTime recordedAt, String source) {
    }

    public record HealthSummary(
            OffsetDateTime from,
            List<HealthLatest> latest,
            Map<String, Double> weekAgo,
            Double bmi,
            long total,
            Map<String, Long> counts,
            long sources,
            long days,
            OffsetDateTime lastRecordAt,
            List<WeightPoint> weightTrend,
            List<HealthRecordView> recent) {
    }

    public record SampleRequest(
            String kind,
            OffsetDateTime recordedAt,
            Double value,
            String source) {
    }

    private final AdminConsoleRepository console;
    private final HealthSampleRepository samples;
    private final AiAnalysisRepository analysis;
    private final LlmClient llm;
    private final ObjectMapper objectMapper;

    public AdminHealthController(AdminConsoleRepository console, HealthSampleRepository samples,
                                 AiAnalysisRepository analysis, LlmClient llm, ObjectMapper objectMapper) {
        this.console = console;
        this.samples = samples;
        this.analysis = analysis;
        this.llm = llm;
        this.objectMapper = objectMapper;
    }

    @PostMapping("/samples")
    public void addSample(@RequestBody SampleRequest request) {
        String kind = request.kind() == null ? "" : request.kind().trim().toLowerCase();
        if (!isKnowKind(kind)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "不支持的类型: " + request.kind());
        }
        if (request.recordedAt() == null || request.value() == null || !Double.isFinite(request.value())) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "记录时间和数值不能为空");
        }
        String source = request.source() == null || request.source().isBlank()
                ? "admin" : request.source().trim();
        samples.upsertAll(List.of(new HealthSampleRepository.HealthSampleInput(
                kind, request.recordedAt(), request.value(), source)));
    }

    @GetMapping("/summary")
    public HealthSummary summary(@RequestParam(defaultValue = "30") int days) {
        int safeDays = Math.min(Math.max(days, 1), 3650);
        OffsetDateTime from = AdminTimes.daysStart(safeDays);

        List<AdminConsoleRepository.HealthRecord> latestRecords = console.latestHealth();
        List<HealthLatest> latest = new ArrayList<>();
        Map<String, Double> latestByKind = new HashMap<>();
        for (AdminConsoleRepository.HealthRecord record : latestRecords) {
            if (!isKnowKind(record.kind())) {
                continue;
            }
            latest.add(new HealthLatest(
                    record.kind(), record.value(), record.recordedAt(), record.source()));
            latestByKind.put(record.kind(), record.value());
        }

        Map<String, Double> weekAgo = new HashMap<>();
        for (AdminConsoleRepository.HealthValue value : console.healthWeekAgo(AdminTimes.now().minusDays(7))) {
            weekAgo.put(value.kind(), value.value());
        }

        Map<String, Long> counts = new HashMap<>();
        for (AdminConsoleRepository.HealthCount count : console.healthCounts()) {
            counts.put(count.kind(), count.total());
        }

        AdminConsoleRepository.HealthStats stats = console.healthStats();
        List<WeightPoint> weightTrend = buildWeightTrend(console.weightTrend(from));
        List<HealthRecordView> recent = console.recentHealth(12).stream()
                .map(record -> new HealthRecordView(
                        record.kind(), record.value(), record.recordedAt(), record.source()))
                .toList();

        return new HealthSummary(
                from,
                latest,
                weekAgo,
                bmi(latestByKind),
                stats.total(),
                counts,
                stats.sources(),
                stats.days(),
                stats.lastRecordAt(),
                weightTrend,
                recent);
    }

    private List<WeightPoint> buildWeightTrend(List<AdminConsoleRepository.HealthPoint> points) {
        Map<String, Double> byDay = new LinkedHashMap<>();
        for (AdminConsoleRepository.HealthPoint point : points) {
            String day = point.recordedAt().atZoneSameInstant(AdminTimes.ZONE).toLocalDate().toString();
            byDay.put(day, point.value());
        }
        List<Map.Entry<String, Double>> entries = new ArrayList<>(byDay.entrySet());
        if (entries.size() > 240) {
            entries = entries.subList(entries.size() - 240, entries.size());
        }
        return entries.stream()
                .map(entry -> new WeightPoint(entry.getKey(), entry.getValue()))
                .toList();
    }

    private Double bmi(Map<String, Double> latest) {
        Double weight = latest.get("weight");
        Double height = latest.get("height");
        if (weight == null || height == null || height <= 0) {
            return null;
        }
        double meters = height / 100.0;
        return Math.round(weight / (meters * meters) * 10.0) / 10.0;
    }

    /* ---------- AI 分析 ---------- */

    private static final String DOMAIN_HEALTH = "health";

    /** 服务端预计算的准确数字，随分析结果一起返回，不依赖模型计算。 */
    public record AiMetrics(
            String startDate,
            String endDate,
            double startWeight,
            double latestWeight,
            double delta,
            double dailyRate,
            int recordedDays,
            Double bmi) {
    }

    public record AiAnalysisResponse(
            boolean cached,
            boolean stale,
            boolean available,
            String model,
            OffsetDateTime analyzedAt,
            JsonNode analysis,
            AiMetrics metrics) {
    }

    private static final String AI_SYSTEM_PROMPT = """
            你是健康数据分析师。只输出一个 JSON 对象，不要输出任何其它文字或 markdown 代码块。字段定义：
            summary：两三句话总结当前状态（趋势方向、区间变化量、整体评价）；
            trend：对象，含 weekly_avg 数组（每项含 week 与 avg_kg，按周聚合的平均体重）和 pace（一句话节奏评价，速度是否健康）；
            anomalies：数组，每项含 date 与 reason（突升突降、连续缺测、周变化速度过快等，没有则空数组）；
            suggestions：数组，2~3 条可执行建议。
            注意：只有体重和身高数据，没有体脂率，不要对体脂/减脂质量做判断。
            """;

    /**
     * AI 分析健康数据。分析结果按「数据指纹 + 统计天数」缓存落库：
     * 健康数据没有新增/修改时直接复用上次结果，不调用 LLM；refresh=true 强制重算；
     * cachedOnly=true 仅查缓存不调 LLM（页面进入时静默展示用）；LLM 失败且存在历史结果时回退并标记 stale。
     */
    @GetMapping("/ai-analysis")
    public AiAnalysisResponse aiAnalysis(
            @RequestParam(defaultValue = "30") int days,
            @RequestParam(defaultValue = "false") boolean refresh,
            @RequestParam(defaultValue = "false") boolean cachedOnly) {
        int safeDays = Math.min(Math.max(days, 1), 365);
        String fingerprint = console.healthFingerprint();
        var cachedRow = analysis.find(DOMAIN_HEALTH, safeDays).orElse(null);
        boolean cacheHit = cachedRow != null && cachedRow.fingerprint().equals(fingerprint);

        if (cachedOnly) {
            if (cacheHit) {
                Gathered cached = gather(safeDays);
                return new AiAnalysisResponse(true, false, true, cachedRow.model(), cachedRow.updatedAt(),
                        parseAnalysis(cachedRow.result()), cached == null ? null : cached.metrics());
            }
            return new AiAnalysisResponse(false, false, false, null, null, null, null);
        }

        Gathered gathered = gather(safeDays);
        if (!refresh && cacheHit && gathered != null) {
            // 健康数据没有变化：直接复用上次结果，不调用 LLM
            return new AiAnalysisResponse(true, false, true, cachedRow.model(), cachedRow.updatedAt(),
                    parseAnalysis(cachedRow.result()), gathered.metrics());
        }

        if (gathered == null) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "暂无体重数据，无法分析");
        }
        if (!llm.configured()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "AI 分析未启用：请在管理台「系统设置」配置 API Key");
        }

        String content;
        try {
            content = llm.chat(AI_SYSTEM_PROMPT, buildPrompt(safeDays, gathered));
        } catch (IllegalStateException exception) {
            if (cachedRow != null) {
                // 限流/超时等失败：回退上次结果，标注数据已更新
                return new AiAnalysisResponse(true, true, true, cachedRow.model(), cachedRow.updatedAt(),
                        parseAnalysis(cachedRow.result()), gathered.metrics());
            }
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "AI 调用失败：" + exception.getMessage(), exception);
        }
        JsonNode analysisJson = parseAnalysis(content);
        if (analysisJson.path("summary").asText("").isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "AI 返回内容缺少 summary 字段");
        }
        analysis.save(DOMAIN_HEALTH, safeDays, fingerprint, llm.model(), analysisJson.toString());
        return new AiAnalysisResponse(false, false, true, llm.model(), AdminTimes.now(), analysisJson, gathered.metrics());
    }

    private record Gathered(List<WeightPoint> weight, AiMetrics metrics) {
    }

    /** 聚合分析输入：体重按天去重（同天取最新）、预计算指标。体脂数值来自客户端同步且单位异常，不参与分析。 */
    private Gathered gather(int days) {
        OffsetDateTime from = AdminTimes.daysStart(days);
        List<WeightPoint> weight = buildWeightTrend(console.weightTrend(from));
        if (weight.isEmpty()) {
            return null;
        }

        double start = weight.get(0).value();
        double latest = weight.get(weight.size() - 1).value();
        long span = Math.max(1, ChronoUnit.DAYS.between(
                LocalDate.parse(weight.get(0).date()), LocalDate.parse(weight.get(weight.size() - 1).date())));
        Map<String, Double> latestByKind = new HashMap<>();
        for (AdminConsoleRepository.HealthRecord record : console.latestHealth()) {
            latestByKind.put(record.kind(), record.value());
        }

        AiMetrics metrics = new AiMetrics(
                weight.get(0).date(),
                weight.get(weight.size() - 1).date(),
                start,
                latest,
                Math.round((latest - start) * 100.0) / 100.0,
                Math.round((latest - start) / span * 1000.0) / 1000.0,
                weight.size(),
                bmi(latestByKind));
        return new Gathered(weight, metrics);
    }

    private String buildPrompt(int days, Gathered gathered) {
        AiMetrics metrics = gathered.metrics();
        StringBuilder prompt = new StringBuilder();
        prompt.append("请分析最近 ").append(days).append(" 天的健康数据。\n");
        prompt.append("统计区间：").append(metrics.startDate()).append(" 至 ").append(metrics.endDate()).append("。\n");
        prompt.append("服务端预计算（数字以此为准）：起始体重 ").append(metrics.startWeight())
                .append(" kg，最新 ").append(metrics.latestWeight())
                .append(" kg，净变化 ").append(metrics.delta())
                .append(" kg，日均 ").append(metrics.dailyRate())
                .append(" kg，有记录 ").append(metrics.recordedDays()).append(" 天");
        if (metrics.bmi() != null) {
            prompt.append("，BMI ").append(metrics.bmi());
        }
        prompt.append("。\n");
        prompt.append("每日体重（kg，按天去重取最新）：").append(toJson(gathered.weight())).append("\n");
        return prompt.toString();
    }

    /** 容错解析：剥掉 markdown 围栏、截取首尾大括号之间的 JSON。 */
    private JsonNode parseAnalysis(String content) {
        String text = content == null ? "" : content.trim();
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        if (start < 0 || end <= start) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "AI 返回内容不是 JSON 对象");
        }
        try {
            return objectMapper.readTree(text.substring(start, end + 1));
        } catch (JsonProcessingException exception) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "AI 返回内容不是合法 JSON", exception);
        }
    }

    private String toJson(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("分析输入序列化失败", exception);
        }
    }

    private static boolean isKnowKind(String kind) {
        return "weight".equals(kind) || "bodyfat".equals(kind) || "height".equals(kind);
    }
}

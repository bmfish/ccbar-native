package com.cc.service.admin;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import com.cc.service.health.HealthSampleRepository;

/** 健康数据汇总（仅管理 Token 可访问）。 */
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

    public AdminHealthController(AdminConsoleRepository console, HealthSampleRepository samples) {
        this.console = console;
        this.samples = samples;
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

    private static boolean isKnowKind(String kind) {
        return "weight".equals(kind) || "bodyfat".equals(kind) || "height".equals(kind);
    }
}

package com.cc.service.audit;

import java.time.OffsetDateTime;
import java.util.List;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.cc.service.admin.AdminTimes;

/** 访问审计统计与明细（仅管理 Token 可访问）。 */
@RestController
@RequestMapping("/api/admin/audit")
public class AuditController {

    private static final int MAX_DAYS = 90;

    public record SummaryResponse(
            OffsetDateTime from,
            OffsetDateTime to,
            int days,
            long total,
            long failed,
            long uniqueUsers,
            double avgDurationMs,
            double p95DurationMs,
            List<AuditRepository.PathStat> topPaths,
            List<AuditRepository.DailyStat> daily,
            List<AuditRepository.StatusStat> statusCodes) {
    }

    private final AuditRepository repository;

    public AuditController(AuditRepository repository) {
        this.repository = repository;
    }

    @GetMapping("/summary")
    public SummaryResponse summary(@RequestParam(defaultValue = "7") int days) {
        int safeDays = Math.min(Math.max(days, 1), MAX_DAYS);
        OffsetDateTime from = AdminTimes.daysStart(safeDays);
        OffsetDateTime to = AdminTimes.now();
        AuditRepository.Summary summary = repository.summary(from);
        return new SummaryResponse(
                from,
                to,
                safeDays,
                summary.total(),
                summary.failed(),
                summary.uniqueUsers(),
                summary.avgDurationMs(),
                summary.p95DurationMs(),
                repository.topPaths(from, 10),
                repository.daily(from),
                repository.statusCodes(from));
    }

    @GetMapping("/logs")
    public AuditRepository.LogPage logs(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(defaultValue = "7") int days,
            @RequestParam(required = false) String method,
            @RequestParam(required = false) String statusClass,
            @RequestParam(required = false) String path) {
        int safeDays = Math.min(Math.max(days, 1), MAX_DAYS);
        return repository.logs(page, size, AdminTimes.daysStart(safeDays), method, statusClass, path);
    }
}

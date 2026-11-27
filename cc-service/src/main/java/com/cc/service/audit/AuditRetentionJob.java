package com.cc.service.audit;

import java.time.OffsetDateTime;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import com.cc.service.admin.AdminTimes;

/** 定期清理过期访问审计，避免审计表无限增长拖慢查询。 */
@Component
public class AuditRetentionJob {

    private static final Logger log = LoggerFactory.getLogger(AuditRetentionJob.class);

    private final AuditRepository repository;
    private final int retentionDays;
    private final int batchSize;

    public AuditRetentionJob(
            AuditRepository repository,
            @Value("${app.audit.retention-days:90}") int retentionDays,
            @Value("${app.audit.delete-batch-size:5000}") int batchSize) {
        this.repository = repository;
        this.retentionDays = Math.max(retentionDays, 7);
        this.batchSize = Math.max(batchSize, 100);
    }

    @Scheduled(initialDelayString = "300000", fixedDelayString = "3600000")
    public void purgeExpired() {
        OffsetDateTime cutoff = AdminTimes.now().minusDays(retentionDays);
        int total = 0;
        for (int round = 0; round < 10; round++) {
            int deleted = repository.deleteBatchBefore(cutoff, batchSize);
            total += deleted;
            if (deleted < batchSize) {
                break;
            }
        }
        if (total > 0) {
            log.info("清理访问审计 {} 条，保留最近 {} 天", total, retentionDays);
        }
    }
}

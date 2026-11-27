package com.cc.service.travel;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** 定时自动同步 12306 订票邮件，对应 iOS 端回前台自动同步 + 10 分钟节流。 */
@Component
public class TravelSyncJob {

    private static final Logger log = LoggerFactory.getLogger(TravelSyncJob.class);

    private final MailSyncEngine engine;
    private final boolean enabled;

    public TravelSyncJob(MailSyncEngine engine,
            @Value("${app.travel.enabled:false}") boolean enabled) {
        this.engine = engine;
        this.enabled = enabled;
    }

    @Scheduled(initialDelayString = "120000", fixedDelayString = "${app.travel.check-interval-ms:300000}")
    public void autoSync() {
        if (!enabled || !engine.credentialsConfigured()) {
            return;
        }
        if (engine.isRunning() || engine.throttled()) {
            return;
        }
        try {
            engine.sync(false);
        } catch (Exception e) {
            log.warn("12306 邮件自动同步失败: {}", e.getMessage());
        }
    }
}

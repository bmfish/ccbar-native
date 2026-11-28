package com.cc.service.travel;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import com.cc.service.settings.AppSettings;

/** 定时自动同步 12306 订票邮件，对应 iOS 端回前台自动同步 + 10 分钟节流。 */
@Component
public class TravelSyncJob {

    private static final Logger log = LoggerFactory.getLogger(TravelSyncJob.class);

    private final MailSyncEngine engine;
    private final AppSettings settings;

    public TravelSyncJob(MailSyncEngine engine, AppSettings settings) {
        this.engine = engine;
        this.settings = settings;
    }

    @Scheduled(initialDelayString = "120000", fixedDelayString = "${app.travel.check-interval-ms:300000}")
    public void autoSync() {
        // 开关来自「系统设置」，管理台改完即生效
        if (!settings.getBool(AppSettings.TRAVEL_ENABLED) || !engine.credentialsConfigured()) {
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

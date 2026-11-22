package com.cc.service.push;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** 每 30 秒检查一次是否到了久坐提醒的时间。 */
@Component
public class PushScheduler {

    private static final Logger log = LoggerFactory.getLogger(PushScheduler.class);

    private final PushService pushService;

    public PushScheduler(PushService pushService) {
        this.pushService = pushService;
    }

    @Scheduled(initialDelayString = "15000", fixedDelayString = "${app.push.check-interval-ms:30000}")
    public void check() {
        try {
            pushService.tick();
        } catch (Exception exception) {
            log.warn("久坐提醒定时检查失败", exception);
        }
    }
}

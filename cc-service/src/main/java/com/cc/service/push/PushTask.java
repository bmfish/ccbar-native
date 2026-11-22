package com.cc.service.push;

import java.time.LocalTime;
import java.time.OffsetDateTime;

/** 一条 Bark 定时推送任务。 */
public record PushTask(
        long id,
        String name,
        boolean enabled,
        String barkUrl,
        String title,
        String taskType,
        String messages,
        String groupName,
        String scheduleType,
        int intervalMinutes,
        LocalTime dailyTime,
        LocalTime activeStart,
        LocalTime activeEnd,
        OffsetDateTime lastSentAt,
        String lastStatus,
        String lastError,
        String lastBody,
        OffsetDateTime createdAt,
        OffsetDateTime updatedAt) {

    public static final String INTERVAL = "INTERVAL";
    public static final String DAILY = "DAILY";

    public static final String TEXT = "TEXT";
    public static final String WEIGHT = "WEIGHT";
    public static final String TOKEN_USAGE = "TOKEN_USAGE";
}

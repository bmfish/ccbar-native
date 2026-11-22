package com.cc.service.admin;

import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;

/** 管理后台统一使用东八区做统计边界，避免部署在 UTC 容器时日期错位。 */
public final class AdminTimes {

    public static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");
    public static final int ONLINE_MINUTES = 5;

    private AdminTimes() {
    }

    public static OffsetDateTime now() {
        return OffsetDateTime.now(ZONE);
    }

    public static OffsetDateTime todayStart() {
        return LocalDate.now(ZONE).atStartOfDay(ZONE).toOffsetDateTime();
    }

    /** 含今天在内最近 days 天的起点。 */
    public static OffsetDateTime daysStart(int days) {
        return LocalDate.now(ZONE).minusDays(Math.max(days, 1) - 1L)
                .atStartOfDay(ZONE).toOffsetDateTime();
    }

    public static OffsetDateTime thisWeekStart() {
        return LocalDate.now(ZONE).with(DayOfWeek.MONDAY)
                .atStartOfDay(ZONE).toOffsetDateTime();
    }

    public static OffsetDateTime onlineSince() {
        return now().minusMinutes(ONLINE_MINUTES);
    }

    public static OffsetDateTime startOfDay(LocalDate date) {
        return date.atStartOfDay(ZONE).toOffsetDateTime();
    }
}

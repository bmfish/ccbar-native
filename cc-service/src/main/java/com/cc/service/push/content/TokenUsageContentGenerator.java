package com.cc.service.push.content;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Locale;

import org.springframework.stereotype.Component;

import com.cc.service.admin.AdminTimes;
import com.cc.service.push.PushTask;
import com.cc.service.usage.UsageEventRepository;

/** Token 用量：汇总今天所有用户的 token 与积分。 */
@Component
public class TokenUsageContentGenerator implements PushContentGenerator {

    private final UsageEventRepository usageEvents;

    public TokenUsageContentGenerator(UsageEventRepository usageEvents) {
        this.usageEvents = usageEvents;
    }

    @Override
    public String taskType() {
        return PushTask.TOKEN_USAGE;
    }

    @Override
    public String generate(PushTask task, OffsetDateTime now) {
        LocalDate today = now.atZoneSameInstant(AdminTimes.ZONE).toLocalDate();
        OffsetDateTime start = AdminTimes.startOfDay(today);
        UsageEventRepository.DailyUsage usage = usageEvents.sumBetween(start, start.plusDays(1));
        if (usage.totalTokens() == 0 && usage.credits() <= 0) {
            String fallback = randomFallback(task);
            return fallback != null ? fallback : "今天还没有 Token 消耗，积分 0。";
        }

        StringBuilder message = new StringBuilder("今日 Token ")
                .append(tokens(usage.totalTokens()))
                .append("（输入 ").append(tokens(usage.inputTokens()))
                .append(" / 输出 ").append(tokens(usage.outputTokens()));
        if (usage.cacheTokens() > 0) {
            message.append(" / 缓存 ").append(tokens(usage.cacheTokens()));
        }
        message.append("），积分 ").append(number(usage.credits())).append("。");
        return message.toString();
    }

    private static String tokens(long value) {
        if (value < 10_000) {
            return String.valueOf(value);
        }
        return String.format(Locale.ROOT, "%.1f 万", value / 10_000.0);
    }

    private static String number(double value) {
        if (Math.abs(value - Math.rint(value)) < 0.05) {
            return String.valueOf(Math.round(value));
        }
        return String.format(Locale.ROOT, "%.1f", value);
    }
}

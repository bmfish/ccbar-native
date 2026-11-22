package com.cc.service.push.content;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Locale;
import java.util.Map;

import org.springframework.stereotype.Component;

import com.cc.service.admin.AdminTimes;
import com.cc.service.push.PushTask;
import com.cc.service.usage.UsageEventRepository;

/** Token 用量：有 Token 就一起推，没有 Token 时只推积分。 */
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

        if (usage.totalTokens() > 0) {
            String breakdown = "输入 " + tokens(usage.inputTokens()) + " / 输出 " + tokens(usage.outputTokens());
            if (usage.cacheTokens() > 0) {
                breakdown += " / 缓存 " + tokens(usage.cacheTokens());
            }
            return MessageTemplates.pick(task, "有Token",
                    Map.of(
                            "tokens", tokens(usage.totalTokens()),
                            "input", tokens(usage.inputTokens()),
                            "output", tokens(usage.outputTokens()),
                            "cache", tokens(usage.cacheTokens()),
                            "breakdown", breakdown,
                            "credits", number(usage.credits())),
                    "今日 Token {tokens}（{breakdown}），积分 {credits}。");
        }

        if (usage.credits() > 0) {
            return MessageTemplates.pick(task, "仅积分",
                    Map.of("credits", number(usage.credits())),
                    "今日积分 {credits}，今天没有 Token 消耗。");
        }

        return MessageTemplates.pick(task, "无消耗", Map.of(),
                "今天没有 Token 消耗，积分 0。");
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

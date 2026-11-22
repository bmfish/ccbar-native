package com.cc.service.push.content;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;

import org.springframework.util.StringUtils;

import com.cc.service.push.PushTask;

/** 按任务类型生成每次实际推送的正文。 */
public interface PushContentGenerator {

    String taskType();

    String generate(PushTask task, OffsetDateTime now);

    /** 从任务的文案池里随机取一条；没有配置时返回 null。 */
    default String randomFallback(PushTask task) {
        if (!StringUtils.hasText(task.messages())) {
            return null;
        }
        List<String> lines = task.messages().lines()
                .map(String::trim)
                .filter(StringUtils::hasText)
                .toList();
        if (lines.isEmpty()) {
            return null;
        }
        return lines.get(ThreadLocalRandom.current().nextInt(lines.size()));
    }
}

package com.cc.service.push.content;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

import org.springframework.util.StringUtils;

import com.cc.service.push.PushTask;

/** 从任务文案池里按场景随机选一条模板，并替换占位符。 */
final class MessageTemplates {

    private MessageTemplates() {
    }

    /**
     * 文案池每行一条；以 [场景] 开头的行只在对应场景生效，没有场景前缀的行所有场景通用。
     * 没有匹配到模板时使用 defaultTemplate。
     */
    static String pick(PushTask task, String scenario, Map<String, String> values, String defaultTemplate) {
        List<String> lines = StringUtils.hasText(task.messages())
                ? task.messages().lines().map(String::trim).filter(StringUtils::hasText).toList()
                : List.of();
        List<String> matched = new ArrayList<>();
        for (String line : lines) {
            String template = line;
            if (line.startsWith("[")) {
                int end = line.indexOf(']');
                if (end > 0) {
                    String tag = line.substring(1, end).trim();
                    if (!tag.equals(scenario)) {
                        continue;
                    }
                    template = line.substring(end + 1).trim();
                }
            }
            if (StringUtils.hasText(template)) {
                matched.add(template);
            }
        }

        String template = matched.isEmpty()
                ? defaultTemplate
                : matched.get(ThreadLocalRandom.current().nextInt(matched.size()));
        for (Map.Entry<String, String> entry : values.entrySet()) {
            template = template.replace("{" + entry.getKey() + "}", entry.getValue());
        }
        return template;
    }
}

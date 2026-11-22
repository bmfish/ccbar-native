package com.cc.service.push.content;

import java.time.OffsetDateTime;

import org.springframework.stereotype.Component;

import com.cc.service.push.PushTask;

/** 静态文案：从多行内容里随机挑一条。 */
@Component
public class TextContentGenerator implements PushContentGenerator {

    @Override
    public String taskType() {
        return PushTask.TEXT;
    }

    @Override
    public String generate(PushTask task, OffsetDateTime now) {
        String message = randomFallback(task);
        if (message == null) {
            throw new IllegalStateException("推送内容为空");
        }
        return message;
    }
}

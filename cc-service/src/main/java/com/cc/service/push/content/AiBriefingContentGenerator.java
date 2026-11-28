package com.cc.service.push.content;

import java.time.OffsetDateTime;

import org.springframework.stereotype.Component;

import com.cc.service.admin.AiBriefingService;
import com.cc.service.push.PushTask;

/** AI 综合简报：把四个板块的 AI 分析汇总成跨领域周报推送到 Bark。文案由 AI 生成，无需模板。 */
@Component
public class AiBriefingContentGenerator implements PushContentGenerator {

    private final AiBriefingService briefingService;

    public AiBriefingContentGenerator(AiBriefingService briefingService) {
        this.briefingService = briefingService;
    }

    @Override
    public String taskType() {
        return PushTask.AI_BRIEFING;
    }

    @Override
    public String generate(PushTask task, OffsetDateTime now) {
        // 异常交给 PushService 记为 FAILED，不打扰手机
        return briefingService.briefing(false, false).text();
    }
}

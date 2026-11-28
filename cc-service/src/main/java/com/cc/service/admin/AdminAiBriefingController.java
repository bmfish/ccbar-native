package com.cc.service.admin;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** 跨板块 AI 综合简报（仅管理 Token 可访问）。 */
@RestController
@RequestMapping("/api/admin/ai-briefing")
public class AdminAiBriefingController {

    private final AiBriefingService briefingService;

    public AdminAiBriefingController(AiBriefingService briefingService) {
        this.briefingService = briefingService;
    }

    @GetMapping
    public AiBriefingService.Briefing briefing(
            @RequestParam(defaultValue = "false") boolean refresh,
            @RequestParam(defaultValue = "false") boolean cachedOnly) {
        return briefingService.briefing(refresh, cachedOnly);
    }
}

package com.cc.service.admin;

import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** AI 数据问答助手（仅管理 Token 可访问）。 */
@RestController
@RequestMapping("/api/admin/ai-ask")
public class AdminAiAskController {

    private final AiAskService askService;

    public AdminAiAskController(AiAskService askService) {
        this.askService = askService;
    }

    @PostMapping
    public AiAskService.AskResponse ask(@RequestBody AiAskService.AskRequest request) {
        return askService.ask(request.question());
    }
}

package com.cc.service.admin;

import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import com.cc.service.llm.LlmClient;
import com.cc.service.settings.AppSettings;

/** 管理台「系统设置」：运行时配置的查看、保存与连通性测试。 */
@RestController
@RequestMapping("/api/admin/settings")
public class AdminSettingsController {

    private static final Logger log = LoggerFactory.getLogger(AdminSettingsController.class);

    private final AppSettings settings;
    private final LlmClient llm;

    public AdminSettingsController(AppSettings settings, LlmClient llm) {
        this.settings = settings;
        this.llm = llm;
    }

    @GetMapping
    public Map<String, Object> view() {
        return settings.view();
    }

    /** 保存一批设置；密钥字段传空串表示保持不变。 */
    @PutMapping
    public Map<String, Object> save(@RequestBody Map<String, String> values) {
        try {
            settings.save(values);
        } catch (IllegalArgumentException exception) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, exception.getMessage());
        }
        log.info("系统设置已更新: {}", values.keySet());
        return view();
    }

    public record LlmTestResult(boolean ok, String model, String reply, long elapsedMs, String error) {
    }

    /** 用当前设置真实调用一次 LLM，验证 Key 与网络连通。 */
    @PostMapping("/llm-test")
    public LlmTestResult testLlm() {
        long started = System.currentTimeMillis();
        try {
            String reply = llm.chat("你是连通性测试助手", "只回复两个字：正常");
            return new LlmTestResult(true, llm.model(), reply,
                    System.currentTimeMillis() - started, null);
        } catch (Exception exception) {
            return new LlmTestResult(false, llm.model(), null,
                    System.currentTimeMillis() - started, exception.getMessage());
        }
    }
}

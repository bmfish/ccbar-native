package com.cc.service.admin;

import java.time.OffsetDateTime;
import java.util.Optional;

import com.cc.service.llm.LlmClient;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

/** AI 分析编排：按板块缓存检查 → 调用 LLM → 容错解析校验 → 结果落库。各管理接口共用。 */
@Service
public class AiAnalysisService {

    /**
     * @param cached 结果来自缓存
     * @param stale  数据有更新但 LLM 调用失败（如限流），回退展示的上一次结果
     */
    public record AiResult(boolean cached, boolean stale, String model, OffsetDateTime analyzedAt, JsonNode analysis) {
    }

    private final AiAnalysisRepository cache;
    private final LlmClient llm;
    private final ObjectMapper objectMapper;

    public AiAnalysisService(AiAnalysisRepository cache, LlmClient llm, ObjectMapper objectMapper) {
        this.cache = cache;
        this.llm = llm;
        this.objectMapper = objectMapper;
    }

    /** 仅查缓存不调 LLM：页面进入时静默取已有结果用。命中返回 cached 结果，未命中返回 empty。 */
    public Optional<AiResult> findCached(String domain, String fingerprint, int days) {
        return cache.find(domain, days)
                .filter(row -> row.fingerprint().equals(fingerprint))
                .map(row -> new AiResult(true, false, row.model(), row.updatedAt(), parse(row.result(), domain)));
    }

    /**
     * 分析指定板块。数据指纹未变化时直接返回缓存（不调 LLM）；refresh=true 强制重算。
     * LLM 调用失败（限流/超时）且存在历史结果时，回退返回历史结果并标记 stale，而不是报错。
     */
    public AiResult analyze(String domain, String fingerprint, int days,
                            String systemPrompt, String userPrompt, boolean refresh) {
        var row = cache.find(domain, days).orElse(null);
        if (!refresh && row != null && row.fingerprint().equals(fingerprint)) {
            return new AiResult(true, false, row.model(), row.updatedAt(), parse(row.result(), domain));
        }
        if (!llm.configured()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "AI 分析未启用：请在管理台「系统设置」配置 API Key");
        }
        String content;
        try {
            content = llm.chat(systemPrompt, userPrompt);
        } catch (IllegalStateException exception) {
            if (row != null) {
                // 限流/超时等失败：回退上次结果，标注数据已更新
                return new AiResult(true, true, row.model(), row.updatedAt(), parse(row.result(), domain));
            }
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "AI 调用失败：" + exception.getMessage(), exception);
        }
        JsonNode analysis = parse(content, domain);
        if (analysis.path("summary").asText("").isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "AI 返回内容缺少 summary 字段");
        }
        cache.save(domain, days, fingerprint, llm.model(), analysis.toString());
        return new AiResult(false, false, llm.model(), AdminTimes.now(), analysis);
    }

    /** 容错解析：截取首尾大括号之间的 JSON，剥掉模型可能带出的多余文字。 */
    public JsonNode parse(String content, String domain) {
        String text = content == null ? "" : content.trim();
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        if (start < 0 || end <= start) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "AI 返回的「" + domain + "」分析不是 JSON 对象");
        }
        try {
            return objectMapper.readTree(text.substring(start, end + 1));
        } catch (Exception exception) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "AI 返回的「" + domain + "」分析不是合法 JSON", exception);
        }
    }
}

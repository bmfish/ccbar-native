package com.cc.service.admin;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import com.cc.service.llm.LlmClient;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

/**
 * 跨板块 AI 综合简报：汇总健康/用量/Trae/旅行四个板块的最新分析结果，一次调用生成综合周报。
 * 简报按「四板块分析的更新时间拼成的指纹」缓存：任何板块重新分析后，简报自动失效。
 */
@Service
public class AiBriefingService {

    public record Briefing(
            boolean cached, boolean stale, boolean available,
            String model, OffsetDateTime analyzedAt, String text) {
    }

    private static final String DOMAIN_BRIEFING = "briefing";
    private static final List<String> SOURCES = List.of("health", "usage", "trae", "travel");

    private static final String SYSTEM_PROMPT = """
            你是个人助理。输入是用户四个板块（健康/用量/Trae账户/旅行）已有的 AI 分析结果。请输出一份跨领域综合简报：
            用 markdown 中文，格式固定为三段：**总览**（一句话）；**跨板块关联**（找单一板块看不到的联动结论，比如计费异常与账户余额的关联、消费与工具使用的关联）；**行动清单**（编号、按紧急度排序、每项标注 [紧急]/[高]/[中]）。
            总长不超过 400 字，不要客套话，不要编造数据里没有的信息。
            """;

    private final AiAnalysisRepository cache;
    private final LlmClient llm;
    private final ObjectMapper objectMapper;

    public AiBriefingService(AiAnalysisRepository cache, LlmClient llm, ObjectMapper objectMapper) {
        this.cache = cache;
        this.llm = llm;
        this.objectMapper = objectMapper;
    }

    public Briefing briefing(boolean refresh, boolean cachedOnly) {
        Map<String, JsonNode> analyses = new LinkedHashMap<>();
        StringBuilder fingerprintSource = new StringBuilder();
        for (String domain : SOURCES) {
            var row = cache.findLatest(domain).orElse(null);
            analyses.put(domain, row == null ? null : parseObject(row.result(), domain));
            fingerprintSource.append(row == null ? "-" : row.updatedAt()).append('|');
        }
        String fingerprint = fingerprintSource.toString();

        if (!refresh) {
            var row = cache.find(DOMAIN_BRIEFING, 0).orElse(null);
            if (row != null && row.fingerprint().equals(fingerprint)) {
                return new Briefing(true, false, true, row.model(), row.updatedAt(), textOf(row.result()));
            }
            if (cachedOnly) {
                return new Briefing(false, false, false, null, null, "");
            }
        }
        if (analyses.values().stream().allMatch(Objects::isNull)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "各板块还没有 AI 分析结果，请先在对应页面点一次「AI 分析」");
        }
        if (!llm.configured()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "AI 分析未启用：请在管理台「系统设置」配置 API Key");
        }

        String userPrompt = buildPrompt(analyses);
        String text;
        try {
            text = llm.chat(SYSTEM_PROMPT, userPrompt).trim();
        } catch (IllegalStateException exception) {
            var row = cache.find(DOMAIN_BRIEFING, 0).orElse(null);
            if (row != null) {
                return new Briefing(true, true, true, row.model(), row.updatedAt(), textOf(row.result()));
            }
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "AI 调用失败：" + exception.getMessage(), exception);
        }
        cache.save(DOMAIN_BRIEFING, 0, fingerprint, llm.model(), toJson(Map.of("text", text)));
        return new Briefing(false, false, true, llm.model(), AdminTimes.now(), text);
    }

    private String buildPrompt(Map<String, JsonNode> analyses) {
        StringBuilder prompt = new StringBuilder("以下是各板块的最新分析结果：\n");
        Map<String, String> titles = Map.of(
                "health", "健康", "usage", "用量", "trae", "Trae 账户", "travel", "旅行");
        for (String domain : SOURCES) {
            JsonNode analysis = analyses.get(domain);
            if (analysis != null) {
                prompt.append("【").append(titles.get(domain)).append("】")
                        .append(analysis.toString()).append("\n");
            }
        }
        prompt.append("请生成综合简报。");
        return prompt.toString();
    }

    private JsonNode parseObject(String result, String domain) {
        try {
            return objectMapper.readTree(result);
        } catch (Exception exception) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "「" + domain + "」的缓存分析不是合法 JSON", exception);
        }
    }

    private String textOf(String result) {
        try {
            return objectMapper.readTree(result).path("text").asText("");
        } catch (Exception exception) {
            return result;
        }
    }

    private String toJson(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (Exception exception) {
            throw new IllegalStateException("简报结果序列化失败", exception);
        }
    }
}

package com.cc.service.llm;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import com.cc.service.settings.AppSettings;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

/**
 * 调用 OpenAI 兼容的 LLM Chat API（默认智谱 GLM 开放平台）。
 *
 * <p>接口地址 / Key / 模型等来自「系统设置」（数据库优先、环境变量兜底），改配置即生效；
 * RestClient 按 base-url + 超时缓存，配置变化时自动重建。免费模型高峰期限流（1305）自动退避重试。</p>
 */
@Component
public class LlmClient {

    private static final Logger log = LoggerFactory.getLogger(LlmClient.class);

    private final ObjectMapper objectMapper;
    private final AppSettings settings;

    private volatile CachedClient cached;

    private record CachedClient(String baseUrl, int readTimeoutMs, RestClient client) {
    }

    public LlmClient(ObjectMapper objectMapper, AppSettings settings) {
        this.objectMapper = objectMapper;
        this.settings = settings;
    }

    public boolean configured() {
        return StringUtils.hasText(settings.get(AppSettings.LLM_API_KEY));
    }

    public String model() {
        return settings.get(AppSettings.LLM_MODEL);
    }

    /** 单轮对话，返回 choices[0].message.content；限流与网络超时自动退避重试。 */
    public String chat(String system, String user) {
        String apiKey = settings.get(AppSettings.LLM_API_KEY);
        if (!StringUtils.hasText(apiKey)) {
            throw new IllegalStateException("AI 分析未启用：请在管理台「系统设置」配置 API Key");
        }
        String model = model();
        boolean thinking = settings.getBool(AppSettings.LLM_THINKING);
        int maxAttempts = Math.max(1, settings.getInt(AppSettings.LLM_MAX_ATTEMPTS, 3));

        List<Map<String, String>> messages = List.of(
                Map.of("role", "system", "content", system),
                Map.of("role", "user", "content", user));
        Map<String, Object> body = new HashMap<>();
        body.put("model", model);
        body.put("temperature", 0.2);
        body.put("messages", messages);
        body.put("thinking", Map.of("type", thinking ? "enabled" : "disabled"));
        String request = toJson(body);

        Exception last = null;
        for (int attempt = 1; attempt <= maxAttempts; attempt++) {
            try {
                // Key 是运行时设置，随请求携带而非固化在缓存的 RestClient 上
                String response = client().post().uri("/chat/completions")
                        .header("Authorization", "Bearer " + apiKey)
                        .contentType(MediaType.APPLICATION_JSON)
                        .body(request)
                        .retrieve().body(String.class);
                return extractContent(response);
            } catch (RestClientResponseException exception) {
                last = exception;
                if (!isRetryable(exception)) {
                    throw new IllegalStateException("LLM 调用失败: "
                            + truncate(exception.getResponseBodyAsString(), 200), exception);
                }
                log.warn("LLM 第 {} 次调用被限流/服务异常，准备重试", attempt);
            } catch (ResourceAccessException exception) {
                last = exception;
                log.warn("LLM 第 {} 次调用网络异常: {}", attempt, exception.getMessage());
            }
            try {
                // 指数退避：2s → 4s → 8s → 16s → 30s（封顶），应对账户级限流的较长恢复窗口
                long backoff = Math.min(2000L << (attempt - 1), 30_000L);
                Thread.sleep(backoff);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("LLM 调用被中断", interrupted);
            }
        }
        throw new IllegalStateException("LLM 连续 " + maxAttempts + " 次调用失败: "
                + (last == null ? "未知原因" : last.getMessage()), last);
    }

    /** 免费模型高峰期返回 1305/1302「访问量过大」，429 与 5xx 也值得重试。 */
    private boolean isRetryable(RestClientResponseException exception) {
        String body = exception.getResponseBodyAsString();
        return exception.getStatusCode().value() == 429
                || exception.getStatusCode().is5xxServerError()
                || body.contains("1305") || body.contains("1302");
    }

    /** 按当前设置取 REST 客户端；base-url 或超时变化时重建。 */
    private RestClient client() {
        String baseUrl = settings.get(AppSettings.LLM_BASE_URL);
        int readTimeoutMs = settings.getInt(AppSettings.LLM_TIMEOUT_MS, 120000);
        CachedClient current = cached;
        if (current == null || !current.baseUrl().equals(baseUrl) || current.readTimeoutMs() != readTimeoutMs) {
            SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
            factory.setConnectTimeout(5000);
            factory.setReadTimeout(readTimeoutMs);
            current = new CachedClient(baseUrl, readTimeoutMs,
                    RestClient.builder().baseUrl(baseUrl).requestFactory(factory).build());
            cached = current;
        }
        return current.client();
    }

    private String extractContent(String response) {
        try {
            JsonNode content = objectMapper.readTree(response)
                    .path("choices").path(0).path("message").path("content");
            if (!content.isTextual() || content.asText().isBlank()) {
                throw new IllegalStateException("LLM 响应缺少 content 字段");
            }
            return content.asText();
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("LLM 响应解析失败", exception);
        }
    }

    private String toJson(Map<String, Object> body) {
        try {
            return objectMapper.writeValueAsString(body);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("LLM 请求序列化失败", exception);
        }
    }

    private static String truncate(String value, int maxLength) {
        if (value == null) {
            return "";
        }
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }
}

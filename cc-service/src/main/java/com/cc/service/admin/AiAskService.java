package com.cc.service.admin;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Map;

import com.cc.service.llm.LlmClient;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

/**
 * AI 数据问答助手：把四个板块的服务端预计算事实打包为上下文，用户用自然语言提问、LLM 以事实为准作答。
 * 每次提问独立（无会话历史），数据实时聚合，不缓存。
 */
@Service
public class AiAskService {

    public record AskRequest(String question) {
    }

    public record AskResponse(String question, String answer, String model, long elapsedMs) {
    }

    private static final String SYSTEM_PROMPT = """
            你是 ccBar 管理台的数据助手。用户会问健康/用量/Trae 账户/旅行相关的问题，回答必须只基于输入给你的事实数据：
            数字以事实为准，不要编造或推算事实里没有的数字；事实不足以回答时直接说明「数据不足」并指出缺什么；
            用简洁中文回答，两三句话以内，除非用户要求展开。今天的日期见数据上下文里的 generatedAt。
            """;

    private final AdminConsoleRepository console;
    private final LlmClient llm;
    private final ObjectMapper objectMapper;

    public AiAskService(AdminConsoleRepository console, LlmClient llm, ObjectMapper objectMapper) {
        this.console = console;
        this.llm = llm;
        this.objectMapper = objectMapper;
    }

    public AskResponse ask(String question) {
        String safeQuestion = question == null ? "" : question.trim();
        if (safeQuestion.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "问题不能为空");
        }
        if (safeQuestion.length() > 300) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "问题太长（最多 300 字）");
        }
        if (!llm.configured()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "AI 未启用：请在管理台「系统设置」配置 API Key");
        }

        long started = System.currentTimeMillis();
        String context = buildContext();
        String answer;
        try {
            answer = llm.chat(SYSTEM_PROMPT,
                    "数据事实：\n" + context + "\n用户问题：" + safeQuestion).trim();
        } catch (IllegalStateException exception) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                    "AI 调用失败：" + exception.getMessage(), exception);
        }
        return new AskResponse(safeQuestion, answer, llm.model(), System.currentTimeMillis() - started);
    }

    /** 四板块事实上下文：全部为服务端预计算的准确数字。 */
    private String buildContext() {
        OffsetDateTime now = AdminTimes.now();
        Map<String, Object> context = new LinkedHashMap<>();
        context.put("generatedAt", now.toString());

        // 用量：近 7/30 天
        OffsetDateTime todayStart = AdminTimes.startOfDay(now.toLocalDate());
        long nowEpoch = now.toEpochSecond();
        context.put("usage7d", console.usageTotals(
                AdminTimes.daysStart(7).toEpochSecond(), nowEpoch, null, "", ""));
        context.put("usage30d", console.usageTotals(
                AdminTimes.daysStart(30).toEpochSecond(), nowEpoch, null, "", ""));
        context.put("topModel30d", console.usageByModel(
                AdminTimes.daysStart(30).toEpochSecond(), nowEpoch, null, "", "", 3));

        // Trae 账户余额
        OffsetDateTime monthStart = now.minusDays(30);
        var traeRows = console.traeQuotas(
                AdminTimes.startOfDay(now.toLocalDate()).toEpochSecond(), nowEpoch);
        context.put("traeAccounts", traeRows.stream()
                .map(row -> Map.of(
                        "account", row.account(),
                        "name", row.name() == null || row.name().isEmpty() ? row.username() : row.name(),
                        "remaining", Math.round((row.total() - row.consumed()) * 10.0) / 10.0,
                        "total", row.total(),
                        "todayCredits", row.todayCredits()))
                .toList());

        // 健康：最新值 + 近 30 天体重趋势
        Map<String, Double> latest = new LinkedHashMap<>();
        for (AdminConsoleRepository.HealthRecord record : console.latestHealth()) {
            latest.put(record.kind(), record.value());
        }
        var trend30 = console.weightTrend(AdminTimes.daysStart(30));
        Double weight30dDelta = trend30.size() >= 2
                ? Math.round((trend30.get(trend30.size() - 1).value() - trend30.get(0).value()) * 100.0) / 100.0
                : null;
        Double height = latest.get("height");
        Double weight = latest.get("weight");
        context.put("health", Map.of(
                "weight", weight == null ? "无记录" : weight,
                "heightCm", height == null ? "无记录" : height,
                "bmi", weight != null && height != null && height > 0
                        ? Math.round(weight / Math.pow(height / 100.0, 2) * 10.0) / 10.0 : "无法计算",
                "weight30dDelta", weight30dDelta == null ? "数据不足" : weight30dDelta,
                "weight30dSamples", trend30.size()));

        // 旅行
        AdminConsoleRepository.TravelAskSummary travel = console.travelAskSummary();
        context.put("travel", Map.of("trips", travel.trips(), "totalCost", travel.cost()));

        try {
            return objectMapper.writeValueAsString(context);
        } catch (Exception exception) {
            throw new IllegalStateException("问答上下文序列化失败", exception);
        }
    }
}

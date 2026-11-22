package com.cc.service.usage;

/** 与 ccBar 本地 usage_log 对齐的用量明细行（created_at 为 epoch 秒）。 */
public record UsageEvent(
        long seq,
        String source,
        String requestId,
        String appType,
        String model,
        long inputTokens,
        long outputTokens,
        long cacheReadTokens,
        long cacheCreationTokens,
        long reasoningTokens,
        double totalCostUsd,
        double credits,
        long requestCount,
        String account,
        String deviceId,
        long createdAt) {
}

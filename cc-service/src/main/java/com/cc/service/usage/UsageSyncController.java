package com.cc.service.usage;

import java.util.List;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.cc.service.api.ApiTokenFilter;
import com.cc.service.auth.UserRepository;

/** 多 Mac 用量汇总：按用户隔离，批量上报 + 按 seq 游标拉取。 */
@RestController
@RequestMapping("/api/usage/events")
public class UsageSyncController {

    private static final int MAX_BATCH = 5000;
    private static final int MAX_PULL = 5000;

    public record EventPayload(
            @NotBlank @Size(max = 64) String source,
            @NotBlank @Size(max = 400) String requestId,
            @Size(max = 100) String appType,
            @Size(max = 200) String model,
            @PositiveOrZero Long inputTokens,
            @PositiveOrZero Long outputTokens,
            @PositiveOrZero Long cacheReadTokens,
            @PositiveOrZero Long cacheCreationTokens,
            @PositiveOrZero Long reasoningTokens,
            @PositiveOrZero Double totalCostUsd,
            @PositiveOrZero Double credits,
            @PositiveOrZero Long requestCount,
            @Size(max = 200) String account,
            @NotNull @PositiveOrZero Long createdAt) {
    }

    public record SyncRequest(
            @Size(max = 100) String deviceId,
            @NotEmpty @Size(max = MAX_BATCH) List<@Valid EventPayload> events) {
    }

    public record SyncResult(int received, int saved) {
    }

    public record PullResult(List<UsageEvent> events, long nextSeq) {
    }

    private final UsageEventRepository repository;
    private final UserRepository users;

    public UsageSyncController(UsageEventRepository repository, UserRepository users) {
        this.repository = repository;
        this.users = users;
    }

    @PostMapping
    public SyncResult sync(
            @RequestAttribute(ApiTokenFilter.USER_ID_ATTRIBUTE) long userId,
            @Valid @RequestBody SyncRequest request) {
        List<UsageEventRepository.EventInput> inputs = request.events().stream()
                .map(this::toInput)
                .toList();
        String deviceId = request.deviceId() == null ? null : request.deviceId().trim();
        if (deviceId != null && !deviceId.isEmpty()) {
            users.touchDevice(userId, deviceId);
        }
        return new SyncResult(inputs.size(), repository.upsertAll(userId, inputs, deviceId));
    }

    @GetMapping
    public PullResult pull(
            @RequestAttribute(ApiTokenFilter.USER_ID_ATTRIBUTE) long userId,
            @RequestParam(defaultValue = "0") long after,
            @RequestParam(defaultValue = "500") int limit) {
        long safeAfter = Math.max(after, 0);
        int safeLimit = Math.min(Math.max(limit, 1), MAX_PULL);
        List<UsageEvent> events = repository.findAfter(userId, safeAfter, safeLimit);
        long nextSeq = events.isEmpty() ? safeAfter : events.get(events.size() - 1).seq();
        return new PullResult(events, nextSeq);
    }

    private UsageEventRepository.EventInput toInput(EventPayload payload) {
        return new UsageEventRepository.EventInput(
                payload.source().trim(),
                payload.requestId().trim(),
                payload.appType(),
                payload.model(),
                valueOrZero(payload.inputTokens()),
                valueOrZero(payload.outputTokens()),
                valueOrZero(payload.cacheReadTokens()),
                valueOrZero(payload.cacheCreationTokens()),
                valueOrZero(payload.reasoningTokens()),
                valueOrZero(payload.totalCostUsd()),
                valueOrZero(payload.credits()),
                payload.requestCount() == null ? 1 : payload.requestCount(),
                payload.account() == null ? "" : payload.account(),
                payload.createdAt());
    }

    private static long valueOrZero(Long value) {
        return value == null ? 0 : value;
    }

    private static double valueOrZero(Double value) {
        return value == null ? 0 : value;
    }
}

package com.cc.service.usage;

import java.time.Instant;
import java.util.List;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;

import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.cc.service.api.ApiTokenFilter;
import com.cc.service.auth.UserRepository;

/** ccbar 把 Trae 官方积分账单（已用 / 总额）快照上报到云端，供管理后台展示余额。 */
@RestController
@RequestMapping("/api/usage/quota")
public class UsageQuotaController {

    private static final int MAX_ACCOUNTS = 20;

    public record QuotaPayload(
            @NotBlank @Size(max = 200) String account,
            @PositiveOrZero Integer slot,
            @PositiveOrZero Double consumed,
            @PositiveOrZero Double total,
            @NotNull @PositiveOrZero Long updatedAt) {
    }

    public record UploadRequest(
            @Size(max = 100) String deviceId,
            @NotEmpty @Size(max = MAX_ACCOUNTS) List<@Valid QuotaPayload> quotas) {
    }

    public record UploadResult(int received, int saved) {
    }

    private final TraeQuotaRepository repository;
    private final UserRepository users;

    public UsageQuotaController(TraeQuotaRepository repository, UserRepository users) {
        this.repository = repository;
        this.users = users;
    }

    @PostMapping
    public UploadResult upload(
            @RequestAttribute(ApiTokenFilter.USER_ID_ATTRIBUTE) long userId,
            @Valid @RequestBody UploadRequest request) {
        String deviceId = request.deviceId() == null ? null : request.deviceId().trim();
        if (deviceId != null && !deviceId.isEmpty()) {
            users.touchDevice(userId, deviceId);
        }
        long now = Instant.now().getEpochSecond();
        List<TraeQuotaRepository.QuotaInput> quotas = request.quotas().stream()
                .map(quota -> new TraeQuotaRepository.QuotaInput(
                        quota.account().trim(),
                        quota.slot() == null ? 0 : quota.slot(),
                        valueOrZero(quota.consumed()),
                        valueOrZero(quota.total()),
                        quota.updatedAt() > 0 ? quota.updatedAt() : now))
                .toList();
        return new UploadResult(quotas.size(), repository.upsertAll(userId, quotas));
    }

    private static double valueOrZero(Double value) {
        return value == null ? 0 : Math.max(0, value);
    }
}

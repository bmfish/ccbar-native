package com.cc.service.auth;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import com.cc.service.api.ApiTokenFilter;

/** 管理员账号登录：用户名 + 密码换取短期会话 Token，服务端只保存哈希。 */
@RestController
public class AdminAuthController {

    private static final int MAX_FAILURES = 8;
    private static final long FAILURE_WINDOW_MS = Duration.ofMinutes(10).toMillis();
    private static final Duration SESSION_TTL = Duration.ofDays(7);
    private static final String BEARER_PREFIX = "Bearer ";

    public record LoginRequest(
            @NotBlank @Size(max = 64) String username,
            @NotBlank @Size(max = 200) String password) {
    }

    public record LoginResponse(String token, String username, OffsetDateTime expiresAt) {
    }

    private final AdminSessionRepository sessions;
    private final String adminUsername;
    private final String adminPasswordHash;
    private final Map<String, Deque<Long>> failures = new ConcurrentHashMap<>();

    public AdminAuthController(
            AdminSessionRepository sessions,
            @Value("${app.admin.username:}") String adminUsername,
            @Value("${app.admin.password-hash:}") String adminPasswordHash) {
        this.sessions = sessions;
        this.adminUsername = adminUsername == null ? "" : adminUsername.trim();
        this.adminPasswordHash = adminPasswordHash == null ? "" : adminPasswordHash.trim();
    }

    @PostMapping("/api/auth/admin-login")
    public LoginResponse login(@Valid @RequestBody LoginRequest request, HttpServletRequest httpRequest) {
        if (adminUsername.isEmpty() || adminPasswordHash.isEmpty()) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "管理员账号登录未启用");
        }
        String ip = clientIp(httpRequest);
        checkRateLimit(ip);
        String presentedUsername = request.username().trim();
        if (!matchesUsername(presentedUsername)
                || !AuthTokens.verifyPassword(request.password(), adminPasswordHash)) {
            recordFailure(ip);
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "用户名或密码错误");
        }
        failures.remove(ip);
        OffsetDateTime now = OffsetDateTime.now();
        sessions.deleteExpired(now);
        String token = AuthTokens.newToken();
        OffsetDateTime expiresAt = now.plus(SESSION_TTL);
        sessions.save(AuthTokens.sha256Hex(token), adminUsername, expiresAt);
        return new LoginResponse(token, adminUsername, expiresAt);
    }

    @PostMapping("/api/admin/logout")
    public void logout(HttpServletRequest request) {
        String token = bearerToken(request);
        if (token != null && !token.isBlank()) {
            sessions.delete(AuthTokens.sha256Hex(token));
        }
    }

    @GetMapping("/api/admin/me")
    public Map<String, String> me(HttpServletRequest request) {
        Object username = request.getAttribute(ApiTokenFilter.ADMIN_USER_ATTRIBUTE);
        return username == null
                ? Map.of("username", "管理员", "type", "token")
                : Map.of("username", String.valueOf(username), "type", "account");
    }

    private boolean matchesUsername(String presented) {
        return MessageDigest.isEqual(
                adminUsername.getBytes(StandardCharsets.UTF_8),
                presented.getBytes(StandardCharsets.UTF_8));
    }

    private void checkRateLimit(String ip) {
        Deque<Long> hits = failures.get(ip);
        if (hits == null) {
            return;
        }
        long cutoff = System.currentTimeMillis() - FAILURE_WINDOW_MS;
        synchronized (hits) {
            while (!hits.isEmpty() && hits.peekFirst() < cutoff) {
                hits.pollFirst();
            }
            if (hits.size() >= MAX_FAILURES) {
                throw new ResponseStatusException(HttpStatus.TOO_MANY_REQUESTS, "尝试次数过多，请 10 分钟后再试");
            }
        }
    }

    private void recordFailure(String ip) {
        Deque<Long> hits = failures.computeIfAbsent(ip, ignored -> new ArrayDeque<>());
        synchronized (hits) {
            hits.addLast(System.currentTimeMillis());
        }
    }

    private static String clientIp(HttpServletRequest request) {
        String forwarded = request.getHeader("X-Forwarded-For");
        if (forwarded != null && !forwarded.isBlank()) {
            return forwarded.split(",")[0].trim();
        }
        return request.getRemoteAddr();
    }

    private static String bearerToken(HttpServletRequest request) {
        String header = request.getHeader(HttpHeaders.AUTHORIZATION);
        if (header != null && header.startsWith(BEARER_PREFIX)) {
            return header.substring(BEARER_PREFIX.length()).trim();
        }
        return null;
    }
}

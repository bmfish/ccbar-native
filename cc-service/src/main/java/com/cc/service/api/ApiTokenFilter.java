package com.cc.service.api;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.filter.OncePerRequestFilter;

import com.cc.service.auth.AuthTokens;
import com.cc.service.auth.UserRepository;

/**
 * /api/** 鉴权：
 * - /api/health 开放；
 * - /api/auth/login 开放（用户名密码换取会话 Token）；
 * - /api/admin/** 只接受管理 Token（app.api-token）；
 * - 其他接口接受用户会话 Token，或管理 Token（映射到 default 用户，兼容旧客户端）。
 * 未配置 app.api-token 时关闭鉴权，所有请求映射到 default 用户，便于本地开发。
 */
@Component
public class ApiTokenFilter extends OncePerRequestFilter {

    public static final String USER_ID_ATTRIBUTE = "cc.userId";

    private static final Logger log = LoggerFactory.getLogger(ApiTokenFilter.class);
    private static final String BEARER_PREFIX = "Bearer ";
    private static final String HEADER_API_KEY = "X-API-Key";
    private static final String AUTH_PATH_PREFIX = "/api/";
    private static final String HEALTH_PATH = "/api/health";
    private static final String LOGIN_PATH = "/api/auth/login";
    private static final String ADMIN_PATH_PREFIX = "/api/admin/";

    private final byte[] expectedToken;
    private final UserRepository users;
    private volatile Long defaultUserId;

    public ApiTokenFilter(@Value("${app.api-token:}") String apiToken, UserRepository users) {
        this.expectedToken = apiToken == null ? new byte[0] : apiToken.trim().getBytes(StandardCharsets.UTF_8);
        this.users = users;
        if (expectedToken.length == 0) {
            log.warn("未配置 API_TOKEN，/api/** 鉴权已关闭");
        }
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        return !path.startsWith(AUTH_PATH_PREFIX) || HEALTH_PATH.equals(path) || LOGIN_PATH.equals(path);
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        String path = request.getRequestURI();

        if (expectedToken.length == 0) {
            request.setAttribute(USER_ID_ATTRIBUTE, defaultUserId());
            filterChain.doFilter(request, response);
            return;
        }

        String presented = extractToken(request);

        if (path.startsWith(ADMIN_PATH_PREFIX)) {
            if (!matchesAdminToken(presented)) {
                unauthorized(response);
                return;
            }
            filterChain.doFilter(request, response);
            return;
        }

        // 管理 Token 沿用旧行为：访问业务接口时归到 default 用户
        if (matchesAdminToken(presented)) {
            request.setAttribute(USER_ID_ATTRIBUTE, defaultUserId());
            filterChain.doFilter(request, response);
            return;
        }

        if (presented == null) {
            unauthorized(response);
            return;
        }

        String tokenHash = AuthTokens.sha256Hex(presented);
        Long userId = users.findUserIdByToken(tokenHash).orElse(null);
        if (userId == null) {
            unauthorized(response);
            return;
        }
        users.touchToken(tokenHash);
        request.setAttribute(USER_ID_ATTRIBUTE, userId);
        filterChain.doFilter(request, response);
    }

    private boolean matchesAdminToken(String presented) {
        return presented != null
                && MessageDigest.isEqual(expectedToken, presented.getBytes(StandardCharsets.UTF_8));
    }

    private long defaultUserId() {
        Long cached = defaultUserId;
        if (cached == null) {
            cached = users.defaultUserId();
            defaultUserId = cached;
        }
        return cached;
    }

    private String extractToken(HttpServletRequest request) {
        String header = request.getHeader(HttpHeaders.AUTHORIZATION);
        if (StringUtils.hasText(header) && header.startsWith(BEARER_PREFIX)) {
            return header.substring(BEARER_PREFIX.length()).trim();
        }
        String apiKey = request.getHeader(HEADER_API_KEY);
        return StringUtils.hasText(apiKey) ? apiKey.trim() : null;
    }

    private void unauthorized(HttpServletResponse response) throws IOException {
        response.setStatus(HttpStatus.UNAUTHORIZED.value());
        response.setHeader(HttpHeaders.WWW_AUTHENTICATE, "Bearer");
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.getWriter().write("{\"error\":\"unauthorized\"}");
    }
}

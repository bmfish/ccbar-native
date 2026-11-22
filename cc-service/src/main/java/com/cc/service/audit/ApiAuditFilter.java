package com.cc.service.audit;

import java.io.IOException;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.filter.OncePerRequestFilter;

import com.cc.service.api.ApiTokenFilter;

/** 记录 /api 请求到审计表，写库失败不影响接口本身。 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class ApiAuditFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(ApiAuditFilter.class);

    private final AuditRepository repository;

    public ApiAuditFilter(AuditRepository repository) {
        this.repository = repository;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        return !path.startsWith("/api/")
                || "/api/health".equals(path)
                || path.startsWith("/api/admin/audit/");
    }

    @Override
    protected void doFilterInternal(
            HttpServletRequest request,
            HttpServletResponse response,
            FilterChain filterChain) throws ServletException, IOException {
        long start = System.nanoTime();
        int status = 500;
        try {
            filterChain.doFilter(request, response);
            status = response.getStatus();
        } catch (ServletException | IOException | RuntimeException exception) {
            status = 500;
            throw exception;
        } finally {
            record(request, status, start);
        }
    }

    private void record(HttpServletRequest request, int status, long startNanos) {
        int durationMs = (int) Math.min(Integer.MAX_VALUE, (System.nanoTime() - startNanos) / 1_000_000);
        Long userId = request.getAttribute(ApiTokenFilter.USER_ID_ATTRIBUTE) instanceof Long id ? id : null;
        try {
            repository.insert(
                    userId,
                    request.getMethod(),
                    request.getRequestURI(),
                    status,
                    durationMs,
                    clientIp(request),
                    request.getHeader("User-Agent"));
        } catch (Exception exception) {
            log.warn("写入访问审计失败: {} {} - {}",
                    request.getMethod(), request.getRequestURI(), exception.getMessage());
        }
    }

    private static String clientIp(HttpServletRequest request) {
        String forwarded = request.getHeader("X-Forwarded-For");
        if (StringUtils.hasText(forwarded)) {
            return forwarded.split(",")[0].trim();
        }
        String realIp = request.getHeader("X-Real-IP");
        if (StringUtils.hasText(realIp)) {
            return realIp.trim();
        }
        return request.getRemoteAddr();
    }
}

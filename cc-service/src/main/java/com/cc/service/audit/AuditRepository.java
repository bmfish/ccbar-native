package com.cc.service.audit;

import java.sql.Types;
import java.time.OffsetDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;
import org.springframework.util.StringUtils;

/** API 访问审计的写入与统计查询。 */
@Repository
public class AuditRepository {

    private static final RowMapper<LogView> LOG_MAPPER = (rs, rowNum) -> new LogView(
            rs.getLong("id"),
            rs.getObject("user_id", Long.class),
            rs.getString("username"),
            rs.getString("method"),
            rs.getString("path"),
            rs.getInt("status"),
            rs.getInt("duration_ms"),
            rs.getString("ip"),
            rs.getString("user_agent"),
            rs.getObject("created_at", OffsetDateTime.class));

    private final JdbcClient jdbcClient;

    public AuditRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    public void insert(
            Long userId,
            String method,
            String path,
            int status,
            int durationMs,
            String ip,
            String userAgent) {
        jdbcClient.sql("""
                        insert into api_audit_log (user_id, method, path, status, duration_ms, ip, user_agent)
                        values (:userId, :method, :path, :status, :durationMs, :ip, :userAgent)
                        """)
                .param("userId", userId, Types.BIGINT)
                .param("method", truncate(method, 10))
                .param("path", truncate(path, 255))
                .param("status", status)
                .param("durationMs", durationMs)
                .param("ip", truncate(ip, 64))
                .param("userAgent", truncate(userAgent, 255))
                .update();
    }

    public Summary summary(OffsetDateTime from) {
        return jdbcClient.sql("""
                        select count(*) as total,
                               count(*) filter (where status >= 400) as failed,
                               count(distinct user_id) as users,
                               coalesce(avg(duration_ms), 0) as avg_ms,
                               coalesce(percentile_cont(0.95) within group (order by duration_ms), 0) as p95_ms
                        from api_audit_log
                        where created_at >= :from
                        """)
                .param("from", from)
                .query((rs, rowNum) -> new Summary(
                        rs.getLong("total"),
                        rs.getLong("failed"),
                        rs.getLong("users"),
                        rs.getDouble("avg_ms"),
                        rs.getDouble("p95_ms")))
                .single();
    }

    public List<PathStat> topPaths(OffsetDateTime from, int limit) {
        return jdbcClient.sql("""
                        select method, path,
                               count(*) as total,
                               count(*) filter (where status >= 400) as failed,
                               coalesce(avg(duration_ms), 0) as avg_ms
                        from api_audit_log
                        where created_at >= :from
                        group by method, path
                        order by total desc, path
                        limit :limit
                        """)
                .param("from", from)
                .param("limit", limit)
                .query((rs, rowNum) -> new PathStat(
                        rs.getString("method"),
                        rs.getString("path"),
                        rs.getLong("total"),
                        rs.getLong("failed"),
                        rs.getDouble("avg_ms")))
                .list();
    }

    public List<DailyStat> daily(OffsetDateTime from) {
        return jdbcClient.sql("""
                        select to_char(created_at at time zone 'Asia/Shanghai', 'YYYY-MM-DD') as day,
                               count(*) as total,
                               count(*) filter (where status >= 400) as failed,
                               coalesce(avg(duration_ms), 0) as avg_ms
                        from api_audit_log
                        where created_at >= :from
                        group by day
                        order by day
                        """)
                .param("from", from)
                .query((rs, rowNum) -> new DailyStat(
                        rs.getString("day"),
                        rs.getLong("total"),
                        rs.getLong("failed"),
                        rs.getDouble("avg_ms")))
                .list();
    }

    public List<StatusStat> statusCodes(OffsetDateTime from) {
        return jdbcClient.sql("""
                        select status, count(*) as total
                        from api_audit_log
                        where created_at >= :from
                        group by status
                        order by total desc, status
                        """)
                .param("from", from)
                .query((rs, rowNum) -> new StatusStat(rs.getInt("status"), rs.getLong("total")))
                .list();
    }

    public LogPage logs(
            int page,
            int size,
            OffsetDateTime from,
            String method,
            String statusClass,
            String path) {
        int safePage = Math.max(page, 1);
        int safeSize = Math.min(Math.max(size, 1), 100);
        StringBuilder where = new StringBuilder(" where l.created_at >= :from");
        Map<String, Object> params = new HashMap<>();
        params.put("from", from);

        if (StringUtils.hasText(method)) {
            where.append(" and l.method = :method");
            params.put("method", method.trim().toUpperCase(Locale.ROOT));
        }
        String statusPrefix = statusClass == null ? "" : statusClass.trim().toLowerCase(Locale.ROOT);
        if (statusPrefix.matches("[1-5]xx")) {
            int base = (statusPrefix.charAt(0) - '0') * 100;
            where.append(" and l.status >= :statusFrom and l.status < :statusTo");
            params.put("statusFrom", base);
            params.put("statusTo", base + 100);
        }
        if (StringUtils.hasText(path)) {
            where.append(" and strpos(lower(l.path), lower(:path)) > 0");
            params.put("path", path.trim());
        }

        long total = jdbcClient.sql("select count(*) from api_audit_log l" + where)
                .params(params)
                .query(Long.class)
                .single();
        List<LogView> items = jdbcClient.sql("""
                        select l.id, l.user_id, u.username, l.method, l.path, l.status,
                               l.duration_ms, l.ip, l.user_agent, l.created_at
                        from api_audit_log l
                        left join app_user u on u.id = l.user_id
                        """ + where + "\n" + """
                        order by l.created_at desc, l.id desc
                        limit :limit offset :offset
                        """)
                .params(params)
                .param("limit", safeSize)
                .param("offset", (long) (safePage - 1) * safeSize)
                .query(LOG_MAPPER)
                .list();
        return new LogPage(items, total, safePage, safeSize);
    }

    public int deleteBatchBefore(OffsetDateTime cutoff, int limit) {
        return jdbcClient.sql("""
                        delete from api_audit_log
                        where id in (
                            select id from api_audit_log
                            where created_at < :cutoff
                            order by created_at
                            limit :limit
                        )
                        """)
                .param("cutoff", cutoff)
                .param("limit", limit)
                .update();
    }

    private static String truncate(String value, int maxLength) {
        if (value == null) {
            return "";
        }
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }

    public record Summary(long total, long failed, long uniqueUsers, double avgDurationMs, double p95DurationMs) {
    }

    public record PathStat(String method, String path, long count, long failed, double avgDurationMs) {
    }

    public record DailyStat(String date, long count, long failed, double avgDurationMs) {
    }

    public record StatusStat(int status, long count) {
    }

    public record LogView(
            long id,
            Long userId,
            String username,
            String method,
            String path,
            int status,
            int durationMs,
            String ip,
            String userAgent,
            OffsetDateTime createdAt) {
    }

    public record LogPage(List<LogView> items, long total, int page, int size) {
    }
}

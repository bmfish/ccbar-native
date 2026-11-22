package com.cc.service.usage;

import java.util.Arrays;
import java.util.List;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

@Repository
public class UsageEventRepository {

    private static final String COLUMNS = """
            seq, source, request_id, app_type, model, input_tokens, output_tokens,
            cache_read_tokens, cache_creation_tokens, reasoning_tokens, total_cost_usd,
            credits, request_count, account, device_id, created_at
            """;

    private static final RowMapper<UsageEvent> ROW_MAPPER = (rs, rowNum) -> new UsageEvent(
            rs.getLong("seq"),
            rs.getString("source"),
            rs.getString("request_id"),
            rs.getString("app_type"),
            rs.getString("model"),
            rs.getLong("input_tokens"),
            rs.getLong("output_tokens"),
            rs.getLong("cache_read_tokens"),
            rs.getLong("cache_creation_tokens"),
            rs.getLong("reasoning_tokens"),
            rs.getDouble("total_cost_usd"),
            rs.getDouble("credits"),
            rs.getLong("request_count"),
            rs.getString("account"),
            rs.getString("device_id"),
            rs.getLong("created_at"));

    /**
     * 幂等 upsert：内容没变时整行不更新，seq 不动，避免多机每天重叠上报导致重复下载；
     * 内容变了（如 Trae 会话继续增长）才推进 seq，让其他设备能拉到更新。
     */
    private static final String UPSERT = """
            insert into usage_event
                (user_id, source, request_id, app_type, model, input_tokens, output_tokens,
                 cache_read_tokens, cache_creation_tokens, reasoning_tokens, total_cost_usd,
                 credits, request_count, account, device_id, created_at, seq)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, nextval('usage_event_seq'))
            on conflict (user_id, source, request_id) do update set
                app_type = excluded.app_type,
                model = excluded.model,
                input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens,
                cache_read_tokens = excluded.cache_read_tokens,
                cache_creation_tokens = excluded.cache_creation_tokens,
                reasoning_tokens = excluded.reasoning_tokens,
                total_cost_usd = excluded.total_cost_usd,
                credits = excluded.credits,
                request_count = excluded.request_count,
                account = excluded.account,
                device_id = excluded.device_id,
                created_at = excluded.created_at,
                updated_at = now(),
                seq = nextval('usage_event_seq')
            where (usage_event.app_type, usage_event.model, usage_event.input_tokens,
                   usage_event.output_tokens, usage_event.cache_read_tokens,
                   usage_event.cache_creation_tokens, usage_event.reasoning_tokens,
                   usage_event.total_cost_usd, usage_event.credits,
                   usage_event.request_count, usage_event.account, usage_event.created_at)
                  is distinct from
                  (excluded.app_type, excluded.model, excluded.input_tokens,
                   excluded.output_tokens, excluded.cache_read_tokens,
                   excluded.cache_creation_tokens, excluded.reasoning_tokens,
                   excluded.total_cost_usd, excluded.credits,
                   excluded.request_count, excluded.account, excluded.created_at)
            """;

    private final JdbcClient jdbcClient;
    private final JdbcTemplate jdbcTemplate;

    public UsageEventRepository(JdbcClient jdbcClient, JdbcTemplate jdbcTemplate) {
        this.jdbcClient = jdbcClient;
        this.jdbcTemplate = jdbcTemplate;
    }

    /** 批量写入，返回实际发生插入/更新的行数。 */
    @Transactional
    public int upsertAll(long userId, List<EventInput> events, String deviceId) {
        if (events.isEmpty()) {
            return 0;
        }
        int[][] rows = jdbcTemplate.batchUpdate(UPSERT, events, events.size(), (ps, event) -> {
            ps.setLong(1, userId);
            ps.setString(2, event.source());
            ps.setString(3, event.requestId());
            ps.setString(4, event.appType());
            ps.setString(5, event.model());
            ps.setLong(6, event.inputTokens());
            ps.setLong(7, event.outputTokens());
            ps.setLong(8, event.cacheReadTokens());
            ps.setLong(9, event.cacheCreationTokens());
            ps.setLong(10, event.reasoningTokens());
            ps.setDouble(11, event.totalCostUsd());
            ps.setDouble(12, event.credits());
            ps.setLong(13, event.requestCount());
            ps.setString(14, event.account());
            ps.setString(15, deviceId);
            ps.setLong(16, event.createdAt());
        });
        return Arrays.stream(rows).flatMapToInt(Arrays::stream).sum();
    }

    /** 按用户 + seq 游标增量拉取（升序）。 */
    public List<UsageEvent> findAfter(long userId, long afterSeq, int limit) {
        return jdbcClient.sql("select " + COLUMNS + " from usage_event"
                        + " where user_id = :userId and seq > :after order by seq asc limit :limit")
                .param("userId", userId)
                .param("after", afterSeq)
                .param("limit", limit)
                .query(ROW_MAPPER)
                .list();
    }

    public record EventInput(
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
            long createdAt) {
    }
}

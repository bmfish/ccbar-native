package com.cc.service.health;

import java.time.OffsetDateTime;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

@Repository
public class HealthSampleRepository {

    private static final String COLUMNS = "id, kind, recorded_at, value, source";

    private static final RowMapper<HealthSample> ROW_MAPPER = (rs, rowNum) -> new HealthSample(
            rs.getLong("id"),
            rs.getString("kind"),
            rs.getObject("recorded_at", OffsetDateTime.class),
            rs.getDouble("value"),
            rs.getString("source"));

    private static final String UPSERT = """
            insert into health_sample (kind, recorded_at, value, source)
            values (?, ?, ?, ?)
            on conflict (kind, recorded_at) do update
            set value = excluded.value, source = excluded.source, updated_at = now()
            """;

    private final JdbcClient jdbcClient;
    private final JdbcTemplate jdbcTemplate;

    public HealthSampleRepository(JdbcClient jdbcClient, JdbcTemplate jdbcTemplate) {
        this.jdbcClient = jdbcClient;
        this.jdbcTemplate = jdbcTemplate;
    }

    /** 批量幂等写入：同一 kind + 记录时间只保留最新值。 */
    @Transactional
    public int upsertAll(List<HealthSampleInput> samples) {
        int[][] rows = jdbcTemplate.batchUpdate(UPSERT, samples, samples.size(), (ps, sample) -> {
            ps.setString(1, sample.kind());
            ps.setObject(2, sample.recordedAt());
            ps.setDouble(3, sample.value());
            ps.setString(4, sample.source());
        });
        return Arrays.stream(rows).flatMapToInt(Arrays::stream).sum();
    }

    public List<HealthSample> find(String kind, OffsetDateTime from, OffsetDateTime to, int limit) {
        StringBuilder sql = new StringBuilder("select " + COLUMNS + " from health_sample where 1 = 1");
        Map<String, Object> params = new HashMap<>();
        if (kind != null) {
            sql.append(" and kind = :kind");
            params.put("kind", kind);
        }
        if (from != null) {
            sql.append(" and recorded_at >= :from");
            params.put("from", from);
        }
        if (to != null) {
            sql.append(" and recorded_at <= :to");
            params.put("to", to);
        }
        sql.append(" order by recorded_at desc limit :limit");
        params.put("limit", limit);

        return jdbcClient.sql(sql.toString())
                .params(params)
                .query(ROW_MAPPER)
                .list();
    }

    public record HealthSampleInput(String kind, OffsetDateTime recordedAt, double value, String source) {
    }
}

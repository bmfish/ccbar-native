package com.cc.service.admin;

import java.time.OffsetDateTime;
import java.util.Optional;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** AI 分析结果缓存（按 domain + days 键：health / usage / trae / travel / briefing），按数据指纹判断是否复用。 */
@Repository
public class AiAnalysisRepository {

    public record AnalysisRow(String domain, int days, String fingerprint, String model, String result, OffsetDateTime updatedAt) {
    }

    private final JdbcClient jdbcClient;

    public AiAnalysisRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    public Optional<AnalysisRow> find(String domain, int days) {
        return jdbcClient.sql("""
                select domain, days, fingerprint, model, result::text as result, updated_at
                from ai_analysis_cache
                where domain = :domain and days = :days
                """)
                .param("domain", domain)
                .param("days", days)
                .query((rs, rowNum) -> new AnalysisRow(
                        rs.getString("domain"),
                        rs.getInt("days"),
                        rs.getString("fingerprint"),
                        rs.getString("model"),
                        rs.getString("result"),
                        rs.getObject("updated_at", OffsetDateTime.class)))
                .optional();
    }

    /** 取板块最新一行（不限天数）：综合简报用——任何板块重新分析都会让简报失效。 */
    public Optional<AnalysisRow> findLatest(String domain) {
        return jdbcClient.sql("""
                select domain, days, fingerprint, model, result::text as result, updated_at
                from ai_analysis_cache
                where domain = :domain
                order by updated_at desc
                limit 1
                """)
                .param("domain", domain)
                .query((rs, rowNum) -> new AnalysisRow(
                        rs.getString("domain"),
                        rs.getInt("days"),
                        rs.getString("fingerprint"),
                        rs.getString("model"),
                        rs.getString("result"),
                        rs.getObject("updated_at", OffsetDateTime.class)))
                .optional();
    }

    public void save(String domain, int days, String fingerprint, String model, String resultJson) {
        jdbcClient.sql("""
                insert into ai_analysis_cache (domain, days, fingerprint, model, result, updated_at)
                values (:domain, :days, :fingerprint, :model, cast(:result as jsonb), now())
                on conflict (domain, days) do update
                set fingerprint = excluded.fingerprint, model = excluded.model,
                    result = excluded.result, updated_at = now()
                """)
                .param("domain", domain)
                .param("days", days)
                .param("fingerprint", fingerprint)
                .param("model", model)
                .param("result", resultJson)
                .update();
    }
}

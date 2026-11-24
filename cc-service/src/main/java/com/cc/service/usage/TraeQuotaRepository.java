package com.cc.service.usage;

import java.util.Arrays;
import java.util.List;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

/** Trae 官方积分账单快照：每个用户、每个账号只保留最新一次上报。 */
@Repository
public class TraeQuotaRepository {

    private static final String UPSERT = """
            insert into trae_account_quota
                (user_id, account, slot, consumed_credits, total_credits, reported_at, updated_at)
            values (?, ?, ?, ?, ?, to_timestamp(?), now())
            on conflict (user_id, account) do update set
                slot = excluded.slot,
                consumed_credits = excluded.consumed_credits,
                total_credits = excluded.total_credits,
                reported_at = excluded.reported_at,
                updated_at = now()
            where excluded.reported_at >= trae_account_quota.reported_at
            """;

    private final JdbcTemplate jdbcTemplate;

    public TraeQuotaRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    @Transactional
    public int upsertAll(long userId, List<QuotaInput> quotas) {
        if (quotas.isEmpty()) {
            return 0;
        }
        int[][] rows = jdbcTemplate.batchUpdate(UPSERT, quotas, quotas.size(), (ps, quota) -> {
            ps.setLong(1, userId);
            ps.setString(2, quota.account());
            ps.setInt(3, quota.slot());
            ps.setDouble(4, quota.consumed());
            ps.setDouble(5, quota.total());
            ps.setLong(6, quota.reportedAt());
        });
        return Arrays.stream(rows).flatMapToInt(Arrays::stream).sum();
    }

    public record QuotaInput(String account, int slot, double consumed, double total, long reportedAt) {
    }
}

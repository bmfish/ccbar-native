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
                (user_id, account, name, slot, consumed_credits, total_credits, reported_at, updated_at)
            values (?, ?, ?, ?, ?, ?, to_timestamp(?), now())
            on conflict (user_id, account) do update set
                name = case when excluded.name <> '' then excluded.name
                            else trae_account_quota.name end,
                slot = excluded.slot,
                consumed_credits = excluded.consumed_credits,
                total_credits = excluded.total_credits,
                reported_at = excluded.reported_at,
                updated_at = now()
            where excluded.reported_at >= trae_account_quota.reported_at
            """;

    private static final String SNAPSHOT = """
            insert into trae_quota_snapshot
                (user_id, account, snapshot_date, consumed_credits, total_credits, reported_at)
            values (?, ?, (to_timestamp(?) at time zone 'Asia/Shanghai')::date, ?, ?, to_timestamp(?))
            on conflict (user_id, account, snapshot_date) do update set
                consumed_credits = excluded.consumed_credits,
                total_credits = excluded.total_credits,
                reported_at = excluded.reported_at
            where excluded.reported_at >= trae_quota_snapshot.reported_at
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
            ps.setString(3, quota.name());
            ps.setInt(4, quota.slot());
            ps.setDouble(5, quota.consumed());
            ps.setDouble(6, quota.total());
            ps.setLong(7, quota.reportedAt());
        });
        jdbcTemplate.batchUpdate(SNAPSHOT, quotas, quotas.size(), (ps, quota) -> {
            ps.setLong(1, userId);
            ps.setString(2, quota.account());
            ps.setLong(3, quota.reportedAt());
            ps.setDouble(4, quota.consumed());
            ps.setDouble(5, quota.total());
            ps.setLong(6, quota.reportedAt());
        });
        return Arrays.stream(rows).flatMapToInt(Arrays::stream).sum();
    }

    public record QuotaInput(String account, String name, int slot, double consumed, double total,
            long reportedAt) {
    }
}

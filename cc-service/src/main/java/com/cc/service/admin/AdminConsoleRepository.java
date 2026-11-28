package com.cc.service.admin;

import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** 管理后台的只读聚合查询与少量维护操作。 */
@Repository
public class AdminConsoleRepository {

    private static final String USAGE_COLUMNS = """
            e.created_at, e.user_id, u.username, e.source, coalesce(e.app_type, '') as app_type,
            coalesce(e.model, '') as model, e.input_tokens, e.output_tokens, e.cache_read_tokens,
            e.cache_creation_tokens, e.reasoning_tokens, e.total_cost_usd, e.credits,
            e.request_count, coalesce(e.account, '') as account, coalesce(e.device_id, '') as device_id
            """;

    private final JdbcClient jdbcClient;

    public AdminConsoleRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    // ---------- 概览 ----------

    public OverviewKpi overviewKpi(OffsetDateTime weekStart, OffsetDateTime todayStart,
            OffsetDateTime now, OffsetDateTime onlineSince) {
        long weekStartEpoch = weekStart.toEpochSecond();
        long todayStartEpoch = todayStart.toEpochSecond();
        long nowEpoch = now.toEpochSecond();
        return jdbcClient.sql("""
                select
                  (select count(*) from app_user) as total_users,
                  (select count(*) from app_user where created_at >= :weekStart) as new_users_week,
                  (select count(*) from user_device) as total_devices,
                  (select count(*) from user_device where last_seen_at >= :onlineSince) as online_devices,
                  u.today_events,
                  u.week_events,
                  u.today_tokens,
                  u.week_tokens,
                  u.today_credits
                from (
                  select
                    count(*) filter (where created_at >= :todayStartEpoch and created_at < :nowEpoch)
                        as today_events,
                    count(*) as week_events,
                    coalesce(sum(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens)
                             filter (where created_at >= :todayStartEpoch and created_at < :nowEpoch), 0)
                        as today_tokens,
                    coalesce(sum(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0)
                        as week_tokens,
                    coalesce(sum(credits)
                             filter (where created_at >= :todayStartEpoch and created_at < :nowEpoch), 0)
                        as today_credits
                  from usage_event
                  where created_at >= :weekStartEpoch and created_at < :nowEpoch
                ) u
                """)
                .param("weekStart", weekStart)
                .param("onlineSince", onlineSince)
                .param("todayStartEpoch", todayStartEpoch)
                .param("weekStartEpoch", weekStartEpoch)
                .param("nowEpoch", nowEpoch)
                .query((rs, rowNum) -> new OverviewKpi(
                        rs.getLong("total_users"),
                        rs.getLong("new_users_week"),
                        rs.getLong("total_devices"),
                        rs.getLong("online_devices"),
                        rs.getLong("today_events"),
                        rs.getLong("week_events"),
                        rs.getLong("today_tokens"),
                        rs.getLong("week_tokens"),
                        rs.getDouble("today_credits")))
                .single();
    }

    public List<DaySourceCount> trend(OffsetDateTime from, OffsetDateTime to) {
        return jdbcClient.sql("""
                select to_char(to_timestamp(e.created_at) at time zone 'Asia/Shanghai', 'YYYY-MM-DD') as day,
                       e.source, count(*) as events
                from usage_event e
                where e.created_at >= :from and e.created_at < :to
                group by 1, 2
                order by 1, 2
                """)
                .param("from", from.toEpochSecond())
                .param("to", to.toEpochSecond())
                .query((rs, rowNum) -> new DaySourceCount(
                        rs.getString("day"),
                        rs.getString("source"),
                        rs.getLong("events")))
                .list();
    }

    public List<HourUsage> hourlyUsage(OffsetDateTime from, OffsetDateTime to) {
        return jdbcClient.sql("""
                select extract(hour from to_timestamp(e.created_at) at time zone 'Asia/Shanghai')::int as hour,
                       count(*) as events,
                       coalesce(sum(e.request_count), 0) as requests,
                       coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                    + e.cache_creation_tokens), 0) as tokens,
                       coalesce(sum(e.credits), 0) as credits
                from usage_event e
                where e.created_at >= :from and e.created_at < :to
                group by 1
                order by 1
                """)
                .param("from", from.toEpochSecond())
                .param("to", to.toEpochSecond())
                .query((rs, rowNum) -> new HourUsage(
                        rs.getInt("hour"),
                        rs.getLong("events"),
                        rs.getLong("requests"),
                        rs.getLong("tokens"),
                        rs.getDouble("credits")))
                .list();
    }

    public List<TraeQuotaRow> traeQuotas(long todayStartEpoch, long nowEpoch) {
        return jdbcClient.sql("""
                select q.user_id, u.username, q.account, q.name, q.slot,
                       q.consumed_credits, q.total_credits, q.reported_at, q.updated_at,
                       coalesce((select sum(e.credits) from usage_event e
                          where e.user_id = q.user_id and e.account = q.account
                            and e.created_at >= :todayStart and e.created_at < :now), 0) as today_credits
                from trae_account_quota q
                join app_user u on u.id = q.user_id
                order by q.slot nulls last, q.account
                """)
                .param("todayStart", todayStartEpoch)
                .param("now", nowEpoch)
                .query((rs, rowNum) -> new TraeQuotaRow(
                        rs.getLong("user_id"),
                        rs.getString("username"),
                        rs.getString("account"),
                        rs.getString("name"),
                        rs.getObject("slot", Integer.class),
                        rs.getDouble("consumed_credits"),
                        rs.getDouble("total_credits"),
                        rs.getObject("reported_at", OffsetDateTime.class),
                        rs.getObject("updated_at", OffsetDateTime.class),
                        rs.getDouble("today_credits")))
                .list();
    }

    /** 近 N 天有用量、但可能没有官方账单快照的 Trae 账号。 */
    public List<TraeUsageAccountRow> traeUsageAccounts(long sinceEpoch, long todayStartEpoch, long nowEpoch) {
        return jdbcClient.sql("""
                select e.user_id, u.username, e.account,
                       coalesce(sum(e.credits), 0) as usage_credits,
                       coalesce(sum(case when e.created_at >= :todayStart and e.created_at < :now
                                         then e.credits else 0 end), 0) as today_credits
                from usage_event e
                join app_user u on u.id = e.user_id
                where e.source = 'trae'
                  and coalesce(e.account, '') <> ''
                  and e.created_at >= :since and e.created_at < :now
                group by e.user_id, u.username, e.account
                """)
                .param("since", sinceEpoch)
                .param("todayStart", todayStartEpoch)
                .param("now", nowEpoch)
                .query((rs, rowNum) -> new TraeUsageAccountRow(
                        rs.getLong("user_id"),
                        rs.getString("username"),
                        rs.getString("account"),
                        rs.getDouble("usage_credits"),
                        rs.getDouble("today_credits")))
                .list();
    }

    /** Trae 账号在指定区间、近 7 天与近 30 天的积分汇总。 */
    public List<TraeAccountUsageRow> traeAccountUsage(long sinceEpoch, long rangeStartEpoch,
            long weekStartEpoch, long todayStartEpoch, long monthStartEpoch, long nowEpoch) {
        return jdbcClient.sql("""
                select e.user_id, u.username, e.account,
                       coalesce(sum(case when e.created_at >= :rangeStart then e.credits else 0 end), 0)
                           as range_credits,
                       coalesce(sum(case when e.created_at >= :weekStart then e.credits else 0 end), 0)
                           as week_credits,
                       coalesce(sum(case when e.created_at >= :todayStart and e.created_at < :now
                                         then e.credits else 0 end), 0) as today_credits,
                       coalesce(sum(case when e.created_at >= :monthStart then e.credits else 0 end), 0)
                           as month_credits,
                       max(e.created_at) as last_usage_at
                from usage_event e
                join app_user u on u.id = e.user_id
                where e.source = 'trae'
                  and coalesce(e.account, '') <> ''
                  and e.created_at >= :since and e.created_at < :now
                group by e.user_id, u.username, e.account
                """)
                .param("since", sinceEpoch)
                .param("rangeStart", rangeStartEpoch)
                .param("weekStart", weekStartEpoch)
                .param("todayStart", todayStartEpoch)
                .param("monthStart", monthStartEpoch)
                .param("now", nowEpoch)
                .query((rs, rowNum) -> new TraeAccountUsageRow(
                        rs.getLong("user_id"),
                        rs.getString("username"),
                        rs.getString("account"),
                        rs.getDouble("range_credits"),
                        rs.getDouble("week_credits"),
                        rs.getDouble("today_credits"),
                        rs.getDouble("month_credits"),
                        epochDateTime(rs.getObject("last_usage_at", Long.class))))
                .list();
    }

    /** Trae 每日各账号积分消耗，用于趋势图。 */
    public List<TraeDailyAccountRow> traeDailyByAccount(long fromEpoch, long toEpoch) {
        return jdbcClient.sql("""
                select e.user_id,
                       to_char(to_timestamp(e.created_at) at time zone 'Asia/Shanghai', 'YYYY-MM-DD') as day,
                       e.account,
                       coalesce(sum(e.credits), 0) as credits
                from usage_event e
                where e.source = 'trae'
                  and coalesce(e.account, '') <> ''
                  and e.created_at >= :from and e.created_at < :to
                group by e.user_id,
                         to_char(to_timestamp(e.created_at) at time zone 'Asia/Shanghai', 'YYYY-MM-DD'),
                         e.account
                order by 2, 1, 3
                """)
                .param("from", fromEpoch)
                .param("to", toEpoch)
                .query((rs, rowNum) -> new TraeDailyAccountRow(
                        rs.getLong("user_id"),
                        rs.getString("day"),
                        rs.getString("account"),
                        rs.getDouble("credits")))
                .list();
    }

    /** Trae 今日每小时各账号积分消耗，用于「今日」趋势。 */
    public List<TraeHourAccountRow> traeHourlyByAccount(long fromEpoch, long toEpoch) {
        return jdbcClient.sql("""
                select e.user_id,
                       extract(hour from to_timestamp(e.created_at) at time zone 'Asia/Shanghai')::int as hour,
                       e.account,
                       coalesce(sum(e.credits), 0) as credits
                from usage_event e
                where e.source = 'trae'
                  and coalesce(e.account, '') <> ''
                  and e.created_at >= :from and e.created_at < :to
                group by e.user_id,
                         extract(hour from to_timestamp(e.created_at) at time zone 'Asia/Shanghai'),
                         e.account
                order by 2, 1, 3
                """)
                .param("from", fromEpoch)
                .param("to", toEpoch)
                .query((rs, rowNum) -> new TraeHourAccountRow(
                        rs.getLong("user_id"),
                        rs.getInt("hour"),
                        rs.getString("account"),
                        rs.getDouble("credits")))
                .list();
    }

    /** 单个 Trae 账号按天汇总，用于账号详情。 */
    public List<TraeDayUsageRow> traeAccountDailyUsage(long userId, String account, long fromEpoch, long toEpoch) {
        return jdbcClient.sql("""
                select to_char(to_timestamp(e.created_at) at time zone 'Asia/Shanghai', 'YYYY-MM-DD') as day,
                       coalesce(sum(e.credits), 0) as credits,
                       coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                    + e.cache_creation_tokens), 0) as tokens,
                       count(*) as events
                from usage_event e
                where e.user_id = :userId and e.source = 'trae'
                  and coalesce(e.account, '') = :account
                  and e.created_at >= :from and e.created_at < :to
                group by 1
                order by 1
                """)
                .param("userId", userId)
                .param("account", account == null ? "" : account)
                .param("from", fromEpoch)
                .param("to", toEpoch)
                .query((rs, rowNum) -> new TraeDayUsageRow(
                        rs.getString("day"),
                        rs.getDouble("credits"),
                        rs.getLong("tokens"),
                        rs.getLong("events")))
                .list();
    }

    public List<ModelAgg> traeAccountModels(long userId, String account, long fromEpoch, long toEpoch, int limit) {
        return jdbcClient.sql("""
                select coalesce(e.model, '') as model,
                       count(*) as events,
                       coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                    + e.cache_creation_tokens), 0) as tokens,
                       coalesce(sum(e.credits), 0) as credits
                from usage_event e
                where e.user_id = :userId and e.source = 'trae'
                  and coalesce(e.account, '') = :account
                  and e.created_at >= :from and e.created_at < :to
                  and coalesce(e.model, '') <> ''
                group by 1
                order by credits desc, tokens desc, events desc
                limit :limit
                """)
                .param("userId", userId)
                .param("account", account == null ? "" : account)
                .param("from", fromEpoch)
                .param("to", toEpoch)
                .param("limit", limit)
                .query((rs, rowNum) -> new ModelAgg(
                        rs.getString("model"),
                        rs.getLong("events"),
                        rs.getLong("tokens"),
                        rs.getDouble("credits")))
                .list();
    }

    public List<UsageRow> traeAccountRecentEvents(long userId, String account, int limit) {
        return jdbcClient.sql("select " + USAGE_COLUMNS + """
                from usage_event e join app_user u on u.id = e.user_id
                where e.user_id = :userId and e.source = 'trae'
                  and coalesce(e.account, '') = :account
                order by e.created_at desc
                limit :limit
                """)
                .param("userId", userId)
                .param("account", account == null ? "" : account)
                .param("limit", limit)
                .query(USAGE_MAPPER)
                .list();
    }

    public List<TraeQuotaPointRow> traeQuotaHistory(long userId, String account, long fromEpoch, long toEpoch) {
        return jdbcClient.sql("""
                select snapshot_date::text as day, consumed_credits, total_credits, reported_at
                from trae_quota_snapshot
                where user_id = :userId and account = :account
                  and snapshot_date >= (to_timestamp(:from) at time zone 'Asia/Shanghai')::date
                  and snapshot_date <= (to_timestamp(:to) at time zone 'Asia/Shanghai')::date
                order by snapshot_date
                """)
                .param("userId", userId)
                .param("account", account == null ? "" : account)
                .param("from", fromEpoch)
                .param("to", toEpoch)
                .query((rs, rowNum) -> new TraeQuotaPointRow(
                        rs.getString("day"),
                        rs.getDouble("consumed_credits"),
                        rs.getDouble("total_credits"),
                        rs.getObject("reported_at", OffsetDateTime.class)))
                .list();
    }

    /** 用量分析：按天、按来源聚合 Token 与积分。 */
    public List<DaySourceUsageRow> usageDailyBySource(long fromEpoch, long toEpoch,
            Long userId, String source, String model) {
        return jdbcClient.sql("""
                select to_char(to_timestamp(e.created_at) at time zone 'Asia/Shanghai', 'YYYY-MM-DD') as day,
                       e.source,
                       coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                    + e.cache_creation_tokens), 0) as tokens,
                       coalesce(sum(e.credits), 0) as credits
                from usage_event e
                """ + usageWhere(userId, source, model) + """
                group by 1, e.source
                order by 1, e.source
                """)
                .params(usageParams(fromEpoch, toEpoch, userId, source, model))
                .query((rs, rowNum) -> new DaySourceUsageRow(
                        rs.getString("day"),
                        rs.getString("source"),
                        rs.getLong("tokens"),
                        rs.getDouble("credits")))
                .list();
    }

    public List<ModelAgg> topModels(OffsetDateTime from, OffsetDateTime to, int limit) {
        return jdbcClient.sql("""
                select coalesce(e.model, '') as model,
                       count(*) as events,
                       coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                    + e.cache_creation_tokens), 0) as tokens,
                       coalesce(sum(e.credits), 0) as credits
                from usage_event e
                where e.created_at >= :from and e.created_at < :to
                  and coalesce(e.model, '') <> ''
                group by 1
                order by tokens desc, credits desc, events desc
                limit :limit
                """)
                .param("from", from.toEpochSecond())
                .param("to", to.toEpochSecond())
                .param("limit", limit)
                .query((rs, rowNum) -> new ModelAgg(
                        rs.getString("model"),
                        rs.getLong("events"),
                        rs.getLong("tokens"),
                        rs.getDouble("credits")))
                .list();
    }

    public List<DeviceRow> recentDevices(int limit) {
        return jdbcClient.sql(deviceSql() + " order by d.last_seen_at desc limit :limit")
                .param("limit", limit)
                .query(DEVICE_MAPPER)
                .list();
    }

    public String migrationVersion() {
        try {
            return jdbcClient.sql("""
                    select version from flyway_schema_history
                    where success = true and version is not null
                    order by installed_rank desc limit 1
                    """)
                    .query(String.class)
                    .optional()
                    .orElse("—");
        } catch (DataAccessException e) {
            return "—";
        }
    }

    public OffsetDateTime lastDeviceSeen() {
        return singleDateTime("select max(last_seen_at) as v from user_device");
    }

    public OffsetDateTime lastUsageUpdate() {
        return singleDateTime("select max(updated_at) as v from usage_event");
    }

    public long activeDevicesSince(OffsetDateTime since) {
        return jdbcClient.sql("select count(*) from user_device where last_seen_at >= :since")
                .param("since", since)
                .query(Long.class)
                .single();
    }

    // ---------- 用户 / 设备 ----------

    public List<AdminUserRow> findAllUsers(OffsetDateTime todayStart, OffsetDateTime weekStart,
            OffsetDateTime now) {
        return jdbcClient.sql(userSql() + " order by u.id")
                .param("todayStart", todayStart.toEpochSecond())
                .param("weekStart", weekStart.toEpochSecond())
                .param("now", now.toEpochSecond())
                .query(USER_MAPPER)
                .list();
    }

    public AdminUserRow findUser(long id, OffsetDateTime todayStart, OffsetDateTime weekStart,
            OffsetDateTime now) {
        return jdbcClient.sql(userSql() + " where u.id = :id")
                .param("id", id)
                .param("todayStart", todayStart.toEpochSecond())
                .param("weekStart", weekStart.toEpochSecond())
                .param("now", now.toEpochSecond())
                .query(USER_MAPPER)
                .optional()
                .orElse(null);
    }

    public List<DeviceRow> findUserDevices(long userId) {
        return jdbcClient.sql(deviceSql() + " where d.user_id = :userId order by d.last_seen_at desc")
                .param("userId", userId)
                .query(DEVICE_MAPPER)
                .list();
    }

    public List<DeviceRow> findAllDevices() {
        return jdbcClient.sql(deviceSql() + " order by d.last_seen_at desc")
                .query(DEVICE_MAPPER)
                .list();
    }

    public int purgeDevicesBefore(OffsetDateTime cutoff) {
        return jdbcClient.sql("delete from user_device where last_seen_at < :cutoff")
                .param("cutoff", cutoff)
                .update();
    }

    // ---------- 用量 ----------

    public UsageTotals usageTotals(long fromEpoch, long toEpoch, Long userId, String source, String model) {
        return jdbcClient.sql("""
                select count(*) as events,
                       coalesce(sum(e.request_count), 0) as requests,
                       coalesce(sum(e.input_tokens), 0) as input_tokens,
                       coalesce(sum(e.output_tokens), 0) as output_tokens,
                       coalesce(sum(e.cache_read_tokens), 0) as cache_read_tokens,
                       coalesce(sum(e.cache_creation_tokens), 0) as cache_creation_tokens,
                       coalesce(sum(e.reasoning_tokens), 0) as reasoning_tokens,
                       coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                    + e.cache_creation_tokens), 0) as tokens,
                       coalesce(sum(e.credits), 0) as credits,
                       coalesce(sum(e.total_cost_usd), 0) as cost_usd,
                       count(distinct e.device_id) as devices,
                       max(e.updated_at) as last_report_at
                from usage_event e
                """ + usageWhere(userId, source, model))
                .params(usageParams(fromEpoch, toEpoch, userId, source, model))
                .query((rs, rowNum) -> new UsageTotals(
                        rs.getLong("events"),
                        rs.getLong("requests"),
                        rs.getLong("input_tokens"),
                        rs.getLong("output_tokens"),
                        rs.getLong("cache_read_tokens"),
                        rs.getLong("cache_creation_tokens"),
                        rs.getLong("reasoning_tokens"),
                        rs.getLong("tokens"),
                        rs.getDouble("credits"),
                        rs.getDouble("cost_usd"),
                        rs.getLong("devices"),
                        rs.getObject("last_report_at", OffsetDateTime.class)))
                .single();
    }

    public List<SourceAgg> usageBySource(long fromEpoch, long toEpoch, Long userId, String source, String model) {
        return jdbcClient.sql("""
                select e.source,
                       count(*) as events,
                       coalesce(sum(e.request_count), 0) as requests,
                       coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                    + e.cache_creation_tokens), 0) as tokens,
                       coalesce(sum(e.credits), 0) as credits
                from usage_event e
                """ + usageWhere(userId, source, model) + """
                group by e.source
                order by events desc, credits desc
                """)
                .params(usageParams(fromEpoch, toEpoch, userId, source, model))
                .query((rs, rowNum) -> new SourceAgg(
                        rs.getString("source"),
                        rs.getLong("events"),
                        rs.getLong("requests"),
                        rs.getLong("tokens"),
                        rs.getDouble("credits")))
                .list();
    }

    public List<ModelAgg> usageByModel(long fromEpoch, long toEpoch, Long userId, String source,
            String model, int limit) {
        return jdbcClient.sql("""
                select coalesce(e.model, '') as model,
                       count(*) as events,
                       coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                    + e.cache_creation_tokens), 0) as tokens,
                       coalesce(sum(e.credits), 0) as credits
                from usage_event e
                """ + usageWhere(userId, source, model) + """
                group by 1
                order by tokens desc, credits desc, events desc
                limit :limit
                """)
                .params(usageParams(fromEpoch, toEpoch, userId, source, model))
                .param("limit", limit)
                .query((rs, rowNum) -> new ModelAgg(
                        rs.getString("model"),
                        rs.getLong("events"),
                        rs.getLong("tokens"),
                        rs.getDouble("credits")))
                .list();
    }

    public List<UsageRow> recentEvents(long fromEpoch, long toEpoch, Long userId, String source,
            String model, int limit) {
        return jdbcClient.sql("select " + USAGE_COLUMNS + """
                from usage_event e join app_user u on u.id = e.user_id
                """ + usageWhere(userId, source, model) + """
                order by e.created_at desc
                limit :limit
                """)
                .params(usageParams(fromEpoch, toEpoch, userId, source, model))
                .param("limit", limit)
                .query(USAGE_MAPPER)
                .list();
    }

    public long countEvents(long fromEpoch, long toEpoch, Long userId, String source, String model) {
        return jdbcClient.sql("select count(*) from usage_event e" + usageWhere(userId, source, model))
                .params(usageParams(fromEpoch, toEpoch, userId, source, model))
                .query(Long.class)
                .single();
    }

    public List<HourBucket> flowHourly(long fromEpoch, long toEpoch, Long userId, String source, String model) {
        return jdbcClient.sql("""
                select (e.created_at / 3600 * 3600) as bucket_epoch,
                       count(*) as events,
                       coalesce(sum(e.request_count), 0) as requests,
                       coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                    + e.cache_creation_tokens), 0) as tokens,
                       coalesce(sum(e.credits), 0) as credits
                from usage_event e
                """ + usageWhere(userId, source, model) + """
                group by 1
                order by 1
                """)
                .params(usageParams(fromEpoch, toEpoch, userId, source, model))
                .query((rs, rowNum) -> new HourBucket(
                        rs.getLong("bucket_epoch"),
                        rs.getLong("events"),
                        rs.getLong("requests"),
                        rs.getLong("tokens"),
                        rs.getDouble("credits")))
                .list();
    }

    public List<String> distinctSources() {
        return jdbcClient.sql("select distinct source from usage_event where source <> '' order by source")
                .query(String.class)
                .list();
    }

    public List<String> distinctModels() {
        return jdbcClient.sql("""
                select distinct model from usage_event
                where model is not null and model <> ''
                order by model
                """)
                .query(String.class)
                .list();
    }

    // ---------- 健康 ----------

    public List<HealthRecord> latestHealth() {
        return jdbcClient.sql("""
                select distinct on (kind) kind, recorded_at, value, source
                from health_sample
                order by kind, recorded_at desc
                """)
                .query(HEALTH_MAPPER)
                .list();
    }

    public List<HealthValue> healthWeekAgo(OffsetDateTime weekAgo) {
        return jdbcClient.sql("""
                select distinct on (kind) kind, value
                from health_sample
                where recorded_at <= :weekAgo
                order by kind, recorded_at desc
                """)
                .param("weekAgo", weekAgo)
                .query((rs, rowNum) -> new HealthValue(
                        rs.getString("kind"),
                        rs.getDouble("value")))
                .list();
    }

    public List<HealthCount> healthCounts() {
        return jdbcClient.sql("select kind, count(*) as total from health_sample group by kind")
                .query((rs, rowNum) -> new HealthCount(
                        rs.getString("kind"),
                        rs.getLong("total")))
                .list();
    }

    public HealthStats healthStats() {
        return jdbcClient.sql("""
                select count(*) as total,
                       count(distinct source) as sources,
                       count(distinct (recorded_at at time zone 'Asia/Shanghai')::date) as days,
                       max(recorded_at) as last_record_at
                from health_sample
                """)
                .query((rs, rowNum) -> new HealthStats(
                        rs.getLong("total"),
                        rs.getLong("sources"),
                        rs.getLong("days"),
                        rs.getObject("last_record_at", OffsetDateTime.class)))
                .single();
    }

    public List<HealthPoint> weightTrend(OffsetDateTime from) {
        return jdbcClient.sql("""
                select recorded_at, value from health_sample
                where kind = 'weight' and recorded_at >= :from
                order by recorded_at asc
                """)
                .param("from", from)
                .query((rs, rowNum) -> new HealthPoint(
                        rs.getObject("recorded_at", OffsetDateTime.class),
                        rs.getDouble("value")))
                .list();
    }

    public List<HealthRecord> recentHealth(int limit) {
        return jdbcClient.sql("""
                select kind, recorded_at, value, source from health_sample
                order by recorded_at desc limit :limit
                """)
                .param("limit", limit)
                .query(HEALTH_MAPPER)
                .list();
    }

    /** 健康数据指纹：任何新增（条数变化）或修改（updated_at 推进）都会改变，用于 AI 分析缓存失效。 */
    public String healthFingerprint() {
        return jdbcClient.sql("""
                select count(*) || ':' || coalesce(max(updated_at)::text, '')
                from health_sample
                """)
                .query(String.class)
                .single();
    }

    /** 用量数据指纹：usage_event 任何新增上报都会改变。 */
    public String usageFingerprint() {
        return jdbcClient.sql("""
                select count(*) || ':' || coalesce(max(updated_at)::text, '')
                from usage_event
                """)
                .query(String.class)
                .single();
    }

    /** Trae 数据指纹：账户配额上报或 Trae 来源用量变化都会改变。 */
    public String traeFingerprint() {
        return jdbcClient.sql("""
                select (select count(*) || ':' || coalesce(max(updated_at)::text, '') from trae_account_quota)
                    || '|' ||
                       (select count(*) || ':' || coalesce(max(updated_at)::text, '')
                        from usage_event where source = 'trae')
                """)
                .query(String.class)
                .single();
    }

    // ---------- 系统 ----------

    public SystemCounts systemCounts() {
        return jdbcClient.sql("""
                select
                  (select count(*) from app_user) as users,
                  (select count(*) from user_device) as devices,
                  (select count(*) from usage_event) as usage_events,
                  (select count(*) from health_sample) as health_samples
                """)
                .query((rs, rowNum) -> new SystemCounts(
                        rs.getLong("users"),
                        rs.getLong("devices"),
                        rs.getLong("usage_events"),
                        rs.getLong("health_samples")))
                .single();
    }

    // ---------- 内部 ----------

    private String userSql() {
        return """
                select u.id, u.username, u.created_at, u.disabled,
                       coalesce(d.device_count, 0) as device_count,
                       d.last_active_at,
                       coalesce(e.today_tokens, 0) as today_tokens,
                       coalesce(e.today_credits, 0) as today_credits,
                       coalesce(e.week_tokens, 0) as week_tokens,
                       coalesce(e.week_credits, 0) as week_credits
                from app_user u
                left join lateral (
                    select count(*) as device_count, max(d.last_seen_at) as last_active_at
                    from user_device d
                    where d.user_id = u.id
                ) d on true
                left join lateral (
                    select
                      coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                   + e.cache_creation_tokens)
                               filter (where e.created_at >= :todayStart and e.created_at < :now), 0)
                          as today_tokens,
                      coalesce(sum(e.credits)
                               filter (where e.created_at >= :todayStart and e.created_at < :now), 0)
                          as today_credits,
                      coalesce(sum(e.input_tokens + e.output_tokens + e.cache_read_tokens
                                   + e.cache_creation_tokens), 0) as week_tokens,
                      coalesce(sum(e.credits), 0) as week_credits
                    from usage_event e
                    where e.user_id = u.id and e.created_at >= :weekStart and e.created_at < :now
                ) e on true
                """;
    }

    private String deviceSql() {
        return """
                select d.device_id, d.user_id, u.username, d.first_seen_at, d.last_seen_at,
                       coalesce(e.event_count, 0) as event_count
                from user_device d
                join app_user u on u.id = d.user_id
                left join lateral (
                    select count(*) as event_count
                    from usage_event e
                    where e.user_id = d.user_id and e.device_id = d.device_id
                ) e on true
                """;
    }

    private static String usageWhere(Long userId, String source, String model) {
        StringBuilder where = new StringBuilder(" where e.created_at >= :from and e.created_at < :to");
        if (userId != null) {
            where.append(" and e.user_id = :userId");
        }
        if (source != null && !source.isBlank()) {
            where.append(" and e.source = :source");
        }
        if (model != null && !model.isBlank()) {
            where.append(" and e.model = :model");
        }
        return where + "\n";
    }

    private static Map<String, Object> usageParams(long fromEpoch, long toEpoch, Long userId,
            String source, String model) {
        Map<String, Object> params = new HashMap<>();
        params.put("from", fromEpoch);
        params.put("to", toEpoch);
        if (userId != null) {
            params.put("userId", userId);
        }
        if (source != null && !source.isBlank()) {
            params.put("source", source);
        }
        if (model != null && !model.isBlank()) {
            params.put("model", model);
        }
        return params;
    }

    private OffsetDateTime singleDateTime(String sql) {
        List<OffsetDateTime> values = jdbcClient.sql(sql)
                .query((rs, rowNum) -> rs.getObject("v", OffsetDateTime.class))
                .list();
        return values.isEmpty() ? null : values.get(0);
    }

    private static OffsetDateTime epochDateTime(Long epochSeconds) {
        return epochSeconds == null ? null : Instant.ofEpochSecond(epochSeconds).atZone(AdminTimes.ZONE).toOffsetDateTime();
    }

    private static final org.springframework.jdbc.core.RowMapper<AdminUserRow> USER_MAPPER =
            (rs, rowNum) -> new AdminUserRow(
                    rs.getLong("id"),
                    rs.getString("username"),
                    rs.getObject("created_at", OffsetDateTime.class),
                    rs.getBoolean("disabled"),
                    rs.getLong("device_count"),
                    rs.getObject("last_active_at", OffsetDateTime.class),
                    rs.getLong("today_tokens"),
                    rs.getDouble("today_credits"),
                    rs.getLong("week_tokens"),
                    rs.getDouble("week_credits"));

    private static final org.springframework.jdbc.core.RowMapper<DeviceRow> DEVICE_MAPPER =
            (rs, rowNum) -> new DeviceRow(
                    rs.getString("device_id"),
                    rs.getLong("user_id"),
                    rs.getString("username"),
                    rs.getObject("first_seen_at", OffsetDateTime.class),
                    rs.getObject("last_seen_at", OffsetDateTime.class),
                    rs.getLong("event_count"));

    private static final org.springframework.jdbc.core.RowMapper<UsageRow> USAGE_MAPPER =
            (rs, rowNum) -> new UsageRow(
                    rs.getLong("created_at"),
                    rs.getLong("user_id"),
                    rs.getString("username"),
                    rs.getString("source"),
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
                    rs.getString("device_id"));

    private static final org.springframework.jdbc.core.RowMapper<HealthRecord> HEALTH_MAPPER =
            (rs, rowNum) -> new HealthRecord(
                    rs.getString("kind"),
                    rs.getObject("recorded_at", OffsetDateTime.class),
                    rs.getDouble("value"),
                    rs.getString("source"));

    public record OverviewKpi(
            long totalUsers,
            long newUsersWeek,
            long totalDevices,
            long onlineDevices,
            long todayEvents,
            long weekEvents,
            long todayTokens,
            long weekTokens,
            double todayCredits) {
    }

    public record DaySourceCount(String day, String source, long events) {
    }

    public record HourUsage(int hour, long events, long requests, long tokens, double credits) {
    }

    public record TraeQuotaRow(
            long userId,
            String username,
            String account,
            String name,
            Integer slot,
            double consumed,
            double total,
            OffsetDateTime reportedAt,
            OffsetDateTime updatedAt,
            double todayCredits) {
    }

    public record TraeUsageAccountRow(
            long userId,
            String username,
            String account,
            double usageCredits,
            double todayCredits) {
    }

    public record TraeAccountUsageRow(
            long userId,
            String username,
            String account,
            double rangeCredits,
            double weekCredits,
            double todayCredits,
            double monthCredits,
            OffsetDateTime lastUsageAt) {
    }

    public record TraeDailyAccountRow(long userId, String day, String account, double credits) {
    }

    public record TraeHourAccountRow(long userId, int hour, String account, double credits) {
    }

    public record TraeDayUsageRow(String day, double credits, long tokens, long events) {
    }

    public record TraeQuotaPointRow(String day, double consumed, double total, OffsetDateTime reportedAt) {
    }

    public record DaySourceUsageRow(String day, String source, long tokens, double credits) {
    }

    public record ModelAgg(String model, long events, long tokens, double credits) {
    }

    public record DeviceRow(
            String deviceId,
            long userId,
            String username,
            OffsetDateTime firstSeenAt,
            OffsetDateTime lastSeenAt,
            long eventCount) {
    }

    public record AdminUserRow(
            long id,
            String username,
            OffsetDateTime createdAt,
            boolean disabled,
            long deviceCount,
            OffsetDateTime lastActiveAt,
            long todayTokens,
            double todayCredits,
            long weekTokens,
            double weekCredits) {
    }

    public record UsageTotals(
            long events,
            long requests,
            long inputTokens,
            long outputTokens,
            long cacheReadTokens,
            long cacheCreationTokens,
            long reasoningTokens,
            long tokens,
            double credits,
            double costUsd,
            long devices,
            OffsetDateTime lastReportAt) {
    }

    public record SourceAgg(String source, long events, long requests, long tokens, double credits) {
    }

    public record UsageRow(
            long createdAt,
            long userId,
            String username,
            String source,
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
            String deviceId) {
    }

    public record HourBucket(long bucketEpoch, long events, long requests, long tokens, double credits) {
    }

    public record HealthRecord(String kind, OffsetDateTime recordedAt, double value, String source) {
    }

    public record HealthValue(String kind, double value) {
    }

    public record HealthCount(String kind, long total) {
    }

    public record HealthPoint(OffsetDateTime recordedAt, double value) {
    }

    public record HealthStats(long total, long sources, long days, OffsetDateTime lastRecordAt) {
    }

    public record SystemCounts(long users, long devices, long usageEvents, long healthSamples) {
    }
}

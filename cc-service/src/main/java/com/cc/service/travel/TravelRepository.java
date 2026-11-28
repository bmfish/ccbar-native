package com.cc.service.travel;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * 旅行票据数据访问：正式票根、候选票根与同步水位。
 * trip_key 全局去重（车次|出发|到达|yyyy.MM.dd），跨邮件、跨批次不会重复建票。
 */
@Repository
public class TravelRepository {

    public record TicketRow(
            long id,
            LocalDate rideDate,
            String departTime,
            String trainNo,
            String fromStation,
            String toStation,
            String coach,
            String seat,
            String seatClass,
            BigDecimal price,
            String passenger,
            String status,
            String note,
            OffsetDateTime createdAt) {
    }

    public record CandidateRow(
            long id,
            String tripKey,
            LocalDate rideDate,
            String departTimeText,
            String trainNo,
            String fromStation,
            String toStation,
            String coach,
            String seat,
            String seatClass,
            BigDecimal price,
            String passenger,
            String orderNo,
            boolean imported,
            boolean dismissed,
            String source,
            OffsetDateTime fetchedAt) {
    }

    public record SyncState(
            String email,
            String owner,
            OffsetDateTime lastSyncAt,
            OffsetDateTime lastFullSyncAt,
            String lastResult) {
    }

    public record TicketPage(long total, List<TicketRow> tickets) {
    }

    /** 导入结果：成功入库数 + 新票样例描述（推送文案用）。 */
    public record ImportResult(int imported, List<String> samples) {
    }

    private final JdbcClient jdbc;

    public TravelRepository(JdbcClient jdbcClient) {
        this.jdbc = jdbcClient;
    }

    /* ---------- 正式票根 ---------- */

    public Set<String> allTicketTripKeys() {
        return new LinkedHashSet<>(jdbc.sql("select trip_key from travel_ticket")
                .query(String.class)
                .list());
    }

    public boolean insertTicket(String tripKey, LocalDate rideDate, String departTime, String trainNo,
            String fromStation, String toStation, String coach, String seat, String seatClass,
            BigDecimal price, String passenger, String source) {
        return jdbc.sql("""
                insert into travel_ticket
                    (trip_key, ride_date, depart_time, train_no, from_station, to_station,
                     coach, seat, seat_class, price, passenger, source)
                values (:tripKey, :rideDate, :departTime, :trainNo, :fromStation, :toStation,
                        :coach, :seat, :seatClass, :price, :passenger, :source)
                on conflict (trip_key) do nothing
                """)
                .param("tripKey", tripKey)
                .param("rideDate", rideDate)
                .param("departTime", departTime)
                .param("trainNo", trainNo)
                .param("fromStation", fromStation)
                .param("toStation", toStation)
                .param("coach", coach)
                .param("seat", seat)
                .param("seatClass", seatClass)
                .param("price", price)
                .param("passenger", passenger)
                .param("source", source)
                .update() > 0;
    }

    /** 退票邮件命中的存量票根标记为已退票。 */
    public int markTicketsRefunded(Collection<String> tripKeys) {
        if (tripKeys.isEmpty()) {
            return 0;
        }
        return jdbc.sql("""
                update travel_ticket set status = 'refunded', updated_at = now()
                where trip_key in (:keys) and status = 'normal'
                """)
                .param("keys", tripKeys)
                .update();
    }

    /** 改签后旧票根标记为已改签（作废）。 */
    public int markTicketsChanged(Collection<String> tripKeys) {
        if (tripKeys.isEmpty()) {
            return 0;
        }
        return jdbc.sql("""
                update travel_ticket set status = 'changed', updated_at = now()
                where trip_key in (:keys) and status = 'normal'
                """)
                .param("keys", tripKeys)
                .update();
    }

    /** 统计用：全量票根，量级几千行，内存聚合与 iOS 端一致。 */
    public List<TicketRow> allTicketsForStats() {
        return jdbc.sql("""
                select id, ride_date, depart_time, train_no, from_station, to_station,
                       coach, seat, seat_class, price, passenger, status, note, created_at
                from travel_ticket
                order by ride_date desc, id desc
                """)
                .query((rs, i) -> new TicketRow(
                        rs.getLong("id"),
                        rs.getObject("ride_date", LocalDate.class),
                        rs.getString("depart_time"),
                        rs.getString("train_no"),
                        rs.getString("from_station"),
                        rs.getString("to_station"),
                        rs.getString("coach"),
                        rs.getString("seat"),
                        rs.getString("seat_class"),
                        rs.getBigDecimal("price"),
                        rs.getString("passenger"),
                        rs.getString("status"),
                        rs.getString("note"),
                        rs.getObject("created_at", OffsetDateTime.class)))
                .list();
    }

    public TicketPage listTickets(String query, String status, int page, int size) {
        String where = " where 1 = 1";
        if (query != null && !query.isBlank()) {
            where += """
                     and (train_no ilike :q or from_station ilike :q or to_station ilike :q
                          or passenger ilike :q or coalesce(note, '') ilike :q)
                    """;
        }
        if (status != null && !status.isBlank()) {
            where += " and status = :status";
        }
        long total = jdbc.sql("select count(*) from travel_ticket" + where)
                .params(params(query, status))
                .query(Long.class)
                .single();
        int offset = Math.max(page - 1, 0) * size;
        List<TicketRow> tickets = jdbc.sql("""
                select id, ride_date, depart_time, train_no, from_station, to_station,
                       coach, seat, seat_class, price, passenger, status, note, created_at
                from travel_ticket
                """ + where + """
                 order by ride_date desc, id desc
                 limit :limit offset :offset
                """)
                .params(params(query, status))
                .param("limit", size)
                .param("offset", offset)
                .query((rs, i) -> new TicketRow(
                        rs.getLong("id"),
                        rs.getObject("ride_date", LocalDate.class),
                        rs.getString("depart_time"),
                        rs.getString("train_no"),
                        rs.getString("from_station"),
                        rs.getString("to_station"),
                        rs.getString("coach"),
                        rs.getString("seat"),
                        rs.getString("seat_class"),
                        rs.getBigDecimal("price"),
                        rs.getString("passenger"),
                        rs.getString("status"),
                        rs.getString("note"),
                        rs.getObject("created_at", OffsetDateTime.class)))
                .list();
        return new TicketPage(total, tickets);
    }

    private java.util.Map<String, Object> params(String query, String status) {
        java.util.Map<String, Object> map = new java.util.HashMap<>();
        if (query != null && !query.isBlank()) {
            map.put("q", "%" + query.trim() + "%");
        }
        if (status != null && !status.isBlank()) {
            map.put("status", status);
        }
        return map;
    }

    /* ---------- 候选票根 ---------- */

    public Set<String> allCandidateTripKeys() {
        return new LinkedHashSet<>(jdbc.sql("select trip_key from travel_mail_candidate")
                .query(String.class)
                .list());
    }

    public boolean insertCandidate(String tripKey, LocalDate rideDate, String departTimeText,
            String trainNo, String fromStation, String toStation, String coach, String seat,
            String seatClass, BigDecimal price, String passenger, String orderNo, String source) {
        return jdbc.sql("""
                insert into travel_mail_candidate
                    (trip_key, ride_date, depart_time_text, train_no, from_station, to_station,
                     coach, seat, seat_class, price, passenger, order_no, source)
                values (:tripKey, :rideDate, :departTimeText, :trainNo, :fromStation, :toStation,
                        :coach, :seat, :seatClass, :price, :passenger, :orderNo, :source)
                on conflict (trip_key) do nothing
                """)
                .param("tripKey", tripKey)
                .param("rideDate", rideDate)
                .param("departTimeText", departTimeText)
                .param("trainNo", trainNo)
                .param("fromStation", fromStation)
                .param("toStation", toStation)
                .param("coach", coach)
                .param("seat", seat)
                .param("seatClass", seatClass)
                .param("price", price)
                .param("passenger", passenger)
                .param("orderNo", orderNo)
                .param("source", source)
                .update() > 0;
    }

    public List<CandidateRow> allCandidates() {
        return jdbc.sql("""
                select id, trip_key, ride_date, depart_time_text, train_no, from_station, to_station,
                       coach, seat, seat_class, price, passenger, order_no, imported, dismissed, source, fetched_at
                from travel_mail_candidate
                order by imported asc, dismissed asc, fetched_at desc
                """)
                .query((rs, i) -> new CandidateRow(
                        rs.getLong("id"),
                        rs.getString("trip_key"),
                        rs.getObject("ride_date", LocalDate.class),
                        rs.getString("depart_time_text"),
                        rs.getString("train_no"),
                        rs.getString("from_station"),
                        rs.getString("to_station"),
                        rs.getString("coach"),
                        rs.getString("seat"),
                        rs.getString("seat_class"),
                        rs.getBigDecimal("price"),
                        rs.getString("passenger"),
                        rs.getString("order_no"),
                        rs.getBoolean("imported"),
                        rs.getBoolean("dismissed"),
                        rs.getString("source"),
                        rs.getObject("fetched_at", OffsetDateTime.class)))
                .list();
    }

    public List<CandidateRow> candidatesByIds(Collection<Long> ids) {
        if (ids.isEmpty()) {
            return List.of();
        }
        return jdbc.sql("""
                select id, trip_key, ride_date, depart_time_text, train_no, from_station, to_station,
                       coach, seat, seat_class, price, passenger, order_no, imported, dismissed, source, fetched_at
                from travel_mail_candidate
                where id in (:ids)
                """)
                .param("ids", ids)
                .query((rs, i) -> new CandidateRow(
                        rs.getLong("id"),
                        rs.getString("trip_key"),
                        rs.getObject("ride_date", LocalDate.class),
                        rs.getString("depart_time_text"),
                        rs.getString("train_no"),
                        rs.getString("from_station"),
                        rs.getString("to_station"),
                        rs.getString("coach"),
                        rs.getString("seat"),
                        rs.getString("seat_class"),
                        rs.getBigDecimal("price"),
                        rs.getString("passenger"),
                        rs.getString("order_no"),
                        rs.getBoolean("imported"),
                        rs.getBoolean("dismissed"),
                        rs.getString("source"),
                        rs.getObject("fetched_at", OffsetDateTime.class)))
                .list();
    }

    public int markCandidatesImported(Collection<Long> ids) {
        if (ids.isEmpty()) {
            return 0;
        }
        return jdbc.sql("update travel_mail_candidate set imported = true where id in (:ids)")
                .param("ids", ids)
                .update();
    }

    public int markCandidatesDismissed(Collection<Long> ids) {
        if (ids.isEmpty()) {
            return 0;
        }
        return jdbc.sql("update travel_mail_candidate set dismissed = true where id in (:ids)")
                .param("ids", ids)
                .update();
    }

    public long countPendingCandidates() {
        return jdbc.sql("select count(*) from travel_mail_candidate where not imported and not dismissed")
                .query(Long.class)
                .single();
    }

    /** 人工确认导入：候选转正式票根（至少要有乘车日期），返回入库数与新票样例。 */
    public ImportResult importCandidates(List<Long> ids) {
        int inserted = 0;
        List<String> samples = new java.util.ArrayList<>();
        for (CandidateRow row : candidatesByIds(ids)) {
            if (row.rideDate() == null) {
                continue;
            }
            boolean ok = insertTicket(row.tripKey(), row.rideDate(), row.departTimeText(),
                    row.trainNo(), row.fromStation(), row.toStation(), row.coach(), row.seat(),
                    row.seatClass(), row.price(), row.passenger(), row.source());
            if (ok) {
                inserted++;
                samples.add(describeCandidate(row));
            }
        }
        markCandidatesImported(ids);
        return new ImportResult(inserted, samples);
    }

    /** 新票样例文案：车次 出发→到达(MM-dd)。 */
    static String describeCandidate(CandidateRow row) {
        String date = row.rideDate() == null ? "" : row.rideDate().format(java.time.format.DateTimeFormatter.ofPattern("MM-dd"));
        return orBlank(row.trainNo()) + " " + orBlank(row.fromStation()) + "→"
                + orBlank(row.toStation()) + "（" + date + "）";
    }

    private static String orBlank(String value) {
        return value == null ? "" : value.trim();
    }

    /* ---------- 同步水位 ---------- */

    /** 旅行数据指纹:新增车票或退票/改签(会更新 updated_at)都会改变,用于 AI 分析缓存失效。 */
    public String travelFingerprint() {
        return jdbc.sql("select count(*) || ':' || coalesce(max(updated_at)::text, '') from travel_ticket")
                .query(String.class)
                .single();
    }

    public SyncState getSyncState() {
        return jdbc.sql("""
                select email, owner, last_sync_at, last_full_sync_at, cast(last_result as text)
                from travel_sync_state where id = 1
                """)
                .query((rs, i) -> new SyncState(
                        rs.getString("email"),
                        rs.getString("owner"),
                        rs.getObject("last_sync_at", OffsetDateTime.class),
                        rs.getObject("last_full_sync_at", OffsetDateTime.class),
                        rs.getString("last_result")))
                .optional()
                .orElse(new SyncState(null, null, null, null, null));
    }

    public void markSynced(String email, String owner, boolean full, String resultJson, OffsetDateTime at) {
        jdbc.sql("""
                update travel_sync_state
                set email = :email, owner = :owner, last_sync_at = :at,
                    last_full_sync_at = case when :full then :at else last_full_sync_at end,
                    last_result = cast(:result as jsonb), updated_at = now()
                where id = 1
                """)
                .param("email", email)
                .param("owner", owner)
                .param("at", at)
                .param("full", full)
                .param("result", resultJson)
                .update();
    }
}

package com.cc.service.push;

import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
public class PushTaskRepository {

    private static final RowMapper<PushTask> TASK_MAPPER = (rs, rowNum) -> new PushTask(
            rs.getLong("id"),
            rs.getString("name"),
            rs.getBoolean("enabled"),
            rs.getString("bark_url"),
            rs.getString("title"),
            rs.getString("task_type"),
            rs.getString("messages"),
            rs.getString("group_name"),
            rs.getString("schedule_type"),
            rs.getInt("interval_minutes"),
            rs.getObject("daily_time", LocalTime.class),
            rs.getObject("active_start", LocalTime.class),
            rs.getObject("active_end", LocalTime.class),
            rs.getObject("last_sent_at", OffsetDateTime.class),
            rs.getString("last_status"),
            rs.getString("last_error"),
            rs.getString("last_body"),
            rs.getObject("created_at", OffsetDateTime.class),
            rs.getObject("updated_at", OffsetDateTime.class));

    private final JdbcClient jdbcClient;

    public PushTaskRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    public List<PushTask> findAll() {
        return jdbcClient.sql("""
                select id, name, enabled, bark_url, title, task_type, messages, group_name, schedule_type,
                       interval_minutes, daily_time, active_start, active_end,
                       last_sent_at, last_status, last_error, last_body, created_at, updated_at
                from push_task order by id
                """)
                .query(TASK_MAPPER)
                .list();
    }

    public List<PushTask> findEnabled() {
        return jdbcClient.sql("""
                select id, name, enabled, bark_url, title, task_type, messages, group_name, schedule_type,
                       interval_minutes, daily_time, active_start, active_end,
                       last_sent_at, last_status, last_error, last_body, created_at, updated_at
                from push_task where enabled = true and bark_url <> '' order by id
                """)
                .query(TASK_MAPPER)
                .list();
    }

    public Optional<PushTask> findById(long id) {
        return jdbcClient.sql("""
                select id, name, enabled, bark_url, title, task_type, messages, group_name, schedule_type,
                       interval_minutes, daily_time, active_start, active_end,
                       last_sent_at, last_status, last_error, last_body, created_at, updated_at
                from push_task where id = :id
                """)
                .param("id", id)
                .query(TASK_MAPPER)
                .optional();
    }

    public long create(PushTaskRequest request, String scheduleType, String taskType) {
        return jdbcClient.sql("""
                insert into push_task (
                    name, enabled, bark_url, title, task_type, messages, group_name, schedule_type,
                    interval_minutes, daily_time, active_start, active_end
                ) values (
                    :name, :enabled, :barkUrl, :title, :taskType, :messages, :groupName, :scheduleType,
                    :intervalMinutes, :dailyTime, :activeStart, :activeEnd
                ) returning id
                """)
                .param("name", request.name().trim())
                .param("enabled", request.enabled())
                .param("barkUrl", request.barkUrl().trim())
                .param("title", request.title().trim())
                .param("taskType", taskType)
                .param("messages", request.messages() == null ? "" : request.messages().trim())
                .param("groupName", request.groupName() == null ? "" : request.groupName().trim())
                .param("scheduleType", scheduleType)
                .param("intervalMinutes", request.intervalMinutes() == null ? 60 : request.intervalMinutes())
                .param("dailyTime", request.dailyTime() == null ? LocalTime.of(9, 0) : request.dailyTime())
                .param("activeStart", request.activeStart())
                .param("activeEnd", request.activeEnd())
                .query(Long.class)
                .single();
    }

    public boolean update(long id, PushTaskRequest request, String scheduleType, String taskType) {
        int rows = jdbcClient.sql("""
                update push_task
                set name = :name,
                    enabled = :enabled,
                    bark_url = :barkUrl,
                    title = :title,
                    task_type = :taskType,
                    messages = :messages,
                    group_name = :groupName,
                    schedule_type = :scheduleType,
                    interval_minutes = :intervalMinutes,
                    daily_time = :dailyTime,
                    active_start = :activeStart,
                    active_end = :activeEnd,
                    updated_at = now()
                where id = :id
                """)
                .param("id", id)
                .param("name", request.name().trim())
                .param("enabled", request.enabled())
                .param("barkUrl", request.barkUrl().trim())
                .param("title", request.title().trim())
                .param("taskType", taskType)
                .param("messages", request.messages() == null ? "" : request.messages().trim())
                .param("groupName", request.groupName() == null ? "" : request.groupName().trim())
                .param("scheduleType", scheduleType)
                .param("intervalMinutes", request.intervalMinutes() == null ? 60 : request.intervalMinutes())
                .param("dailyTime", request.dailyTime() == null ? LocalTime.of(9, 0) : request.dailyTime())
                .param("activeStart", request.activeStart())
                .param("activeEnd", request.activeEnd())
                .update();
        return rows > 0;
    }

    public boolean delete(long id) {
        return jdbcClient.sql("delete from push_task where id = :id")
                .param("id", id)
                .update() > 0;
    }

    public void markResult(long id, OffsetDateTime sentAt, String status, String error, String body) {
        jdbcClient.sql("""
                update push_task
                set last_sent_at = :sentAt,
                    last_status = :status,
                    last_error = :error,
                    last_body = :body,
                    updated_at = now()
                where id = :id
                """)
                .param("id", id)
                .param("sentAt", sentAt)
                .param("status", status)
                .param("error", error == null ? "" : error)
                .param("body", body == null ? "" : body)
                .update();
    }
}

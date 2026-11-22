package com.cc.service.auth;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
public class UserRepository {

    private static final RowMapper<User> USER_MAPPER = (rs, rowNum) -> new User(
            rs.getLong("id"),
            rs.getString("username"),
            rs.getString("password_hash"),
            rs.getObject("created_at", OffsetDateTime.class),
            rs.getBoolean("disabled"));

    private final JdbcClient jdbcClient;

    public UserRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    public Optional<User> findByUsername(String username) {
        return jdbcClient.sql("""
                select id, username, password_hash, created_at, disabled
                from app_user where username = :username
                """)
                .param("username", username)
                .query(USER_MAPPER)
                .optional();
    }

    public User create(String username, String passwordHash) {
        return jdbcClient.sql("""
                insert into app_user (username, password_hash)
                values (:username, :passwordHash)
                returning id, username, password_hash, created_at, disabled
                """)
                .param("username", username)
                .param("passwordHash", passwordHash)
                .query(USER_MAPPER)
                .single();
    }

    public boolean updatePassword(long userId, String passwordHash) {
        int rows = jdbcClient.sql("""
                update app_user set password_hash = :passwordHash, updated_at = now()
                where id = :id
                """)
                .param("passwordHash", passwordHash)
                .param("id", userId)
                .update();
        return rows > 0;
    }

    public long defaultUserId() {
        return jdbcClient.sql("select id from app_user where username = 'default'")
                .query(Long.class)
                .single();
    }

    public List<UserView> findAll() {
        return jdbcClient.sql("""
                select u.id, u.username, u.created_at, u.disabled,
                       (select count(*) from user_device d where d.user_id = u.id) as device_count
                from app_user u
                order by u.id
                """)
                .query((rs, rowNum) -> new UserView(
                        rs.getLong("id"),
                        rs.getString("username"),
                        rs.getObject("created_at", OffsetDateTime.class),
                        rs.getLong("device_count"),
                        rs.getBoolean("disabled")))
                .list();
    }

    public void saveToken(long userId, String tokenHash) {
        jdbcClient.sql("""
                insert into user_token (token_hash, user_id)
                values (:tokenHash, :userId)
                """)
                .param("tokenHash", tokenHash)
                .param("userId", userId)
                .update();
    }

    public Optional<Long> findUserIdByToken(String tokenHash) {
        return jdbcClient.sql("""
                select t.user_id from user_token t
                join app_user u on u.id = t.user_id
                where t.token_hash = :tokenHash and not u.disabled
                """)
                .param("tokenHash", tokenHash)
                .query(Long.class)
                .optional();
    }

    public void touchToken(String tokenHash) {
        jdbcClient.sql("update user_token set last_used_at = now() where token_hash = :tokenHash")
                .param("tokenHash", tokenHash)
                .update();
    }

    public void deleteTokens(long userId) {
        jdbcClient.sql("delete from user_token where user_id = :userId")
                .param("userId", userId)
                .update();
    }

    public boolean setDisabled(long userId, boolean disabled) {
        int rows = jdbcClient.sql("""
                update app_user set disabled = :disabled, updated_at = now()
                where id = :id
                """)
                .param("disabled", disabled)
                .param("id", userId)
                .update();
        return rows > 0;
    }

    public void touchDevice(long userId, String deviceId) {
        jdbcClient.sql("""
                insert into user_device (user_id, device_id)
                values (:userId, :deviceId)
                on conflict (user_id, device_id) do update set last_seen_at = now()
                """)
                .param("userId", userId)
                .param("deviceId", deviceId)
                .update();
    }

    public List<DeviceView> findDevices(long userId) {
        return jdbcClient.sql("""
                select device_id, first_seen_at, last_seen_at
                from user_device where user_id = :userId
                order by last_seen_at desc
                """)
                .param("userId", userId)
                .query((rs, rowNum) -> new DeviceView(
                        rs.getString("device_id"),
                        rs.getObject("first_seen_at", OffsetDateTime.class),
                        rs.getObject("last_seen_at", OffsetDateTime.class)))
                .list();
    }

    public record User(
            long id,
            String username,
            String passwordHash,
            OffsetDateTime createdAt,
            boolean disabled) {
    }

    public record UserView(
            long id,
            String username,
            OffsetDateTime createdAt,
            long deviceCount,
            boolean disabled) {
    }

    public record DeviceView(String deviceId, OffsetDateTime firstSeenAt, OffsetDateTime lastSeenAt) {
    }
}

package com.cc.service.auth;

import java.time.OffsetDateTime;
import java.util.Optional;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** 管理员账号登录会话，服务端只保存 Token 哈希。 */
@Repository
public class AdminSessionRepository {

    private final JdbcClient jdbcClient;

    public AdminSessionRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    public void save(String tokenHash, String username, OffsetDateTime expiresAt) {
        jdbcClient.sql("""
                insert into admin_session (token_hash, username, expires_at)
                values (:tokenHash, :username, :expiresAt)
                on conflict (token_hash) do update set
                    username = excluded.username,
                    expires_at = excluded.expires_at
                """)
                .param("tokenHash", tokenHash)
                .param("username", username)
                .param("expiresAt", expiresAt)
                .update();
    }

    public Optional<String> findActive(String tokenHash, OffsetDateTime now) {
        return jdbcClient.sql("""
                select username from admin_session
                where token_hash = :tokenHash and expires_at > :now
                """)
                .param("tokenHash", tokenHash)
                .param("now", now)
                .query(String.class)
                .optional();
    }

    public boolean delete(String tokenHash) {
        return jdbcClient.sql("delete from admin_session where token_hash = :tokenHash")
                .param("tokenHash", tokenHash)
                .update() > 0;
    }

    public int deleteExpired(OffsetDateTime now) {
        return jdbcClient.sql("delete from admin_session where expires_at <= :now")
                .param("now", now)
                .update();
    }
}

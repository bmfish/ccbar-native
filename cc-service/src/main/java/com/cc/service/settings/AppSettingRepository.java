package com.cc.service.settings;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** 系统设置的 key-value 存取。 */
@Repository
public class AppSettingRepository {

    private final JdbcClient jdbcClient;

    public AppSettingRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    /** 全部已保存的设置（不含环境变量兜底值）。 */
    public Map<String, String> findAll() {
        Map<String, String> values = new LinkedHashMap<>();
        for (Map.Entry<String, String> entry : jdbcClient.sql("select key, value from app_setting order by key")
                .query((rs, rowNum) -> Map.entry(rs.getString("key"), rs.getString("value")))
                .list()) {
            values.put(entry.getKey(), entry.getValue());
        }
        return values;
    }

    /** 保存或更新，返回受影响行数。 */
    public int save(String key, String value) {
        return jdbcClient.sql("""
                insert into app_setting (key, value) values (:key, :value)
                on conflict (key) do update set value = excluded.value, updated_at = now()
                """)
                .param("key", key)
                .param("value", value)
                .update();
    }
}

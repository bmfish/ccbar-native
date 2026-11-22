package com.cc.service.api;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class HealthController {

    private final JdbcClient jdbcClient;

    public HealthController(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    @GetMapping("/health")
    public Map<String, Object> health() {
        boolean dbUp;
        try {
            dbUp = jdbcClient.sql("select 1").query(Integer.class).single() == 1;
        } catch (Exception e) {
            dbUp = false;
        }

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", dbUp ? "UP" : "DEGRADED");
        body.put("db", dbUp ? "UP" : "DOWN");
        body.put("time", OffsetDateTime.now().toString());
        return body;
    }
}

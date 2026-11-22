package com.cc.service.health;

import java.time.OffsetDateTime;

public record HealthSample(Long id, String kind, OffsetDateTime recordedAt, double value, String source) {
}

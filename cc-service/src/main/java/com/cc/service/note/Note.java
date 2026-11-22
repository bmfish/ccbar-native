package com.cc.service.note;

import java.time.OffsetDateTime;

public record Note(Long id, String title, String content, OffsetDateTime createdAt, OffsetDateTime updatedAt) {
}

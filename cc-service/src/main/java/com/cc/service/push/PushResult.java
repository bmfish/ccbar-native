package com.cc.service.push;

import java.time.OffsetDateTime;

public record PushResult(boolean success, String message, OffsetDateTime sentAt) {
}

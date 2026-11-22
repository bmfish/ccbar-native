package com.cc.service.push;

import java.time.LocalTime;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/** 新增或编辑推送任务。 */
public record PushTaskRequest(
        @NotBlank @Size(max = 100) String name,
        boolean enabled,
        @NotBlank @Size(max = 500) String barkUrl,
        @NotBlank @Size(max = 100) String title,
        @Size(max = 20) String taskType,
        @Size(min = 0, max = 2000) String messages,
        @Size(max = 100) String groupName,
        @NotBlank String scheduleType,
        @Min(1) @Max(1440) Integer intervalMinutes,
        LocalTime dailyTime,
        @NotNull LocalTime activeStart,
        @NotNull LocalTime activeEnd) {
}

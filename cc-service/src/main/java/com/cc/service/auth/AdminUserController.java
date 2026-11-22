package com.cc.service.auth;

import java.time.OffsetDateTime;
import java.util.List;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import com.cc.service.admin.AdminConsoleRepository;
import com.cc.service.admin.AdminTimes;

/** 用户与设备管理（仅管理 Token 可访问）。 */
@RestController
@RequestMapping("/api/admin/users")
public class AdminUserController {

    public record CreateUserRequest(
            @NotBlank @Pattern(regexp = "[A-Za-z0-9_.-]{2,64}") String username,
            @NotBlank @Size(min = 6, max = 100) String password) {
    }

    public record ResetPasswordRequest(
            @NotBlank @Size(min = 6, max = 100) String password) {
    }

    public record StatusRequest(@NotNull Boolean disabled) {
    }

    public record DeviceView(
            String deviceId,
            OffsetDateTime firstSeenAt,
            OffsetDateTime lastSeenAt,
            boolean online,
            long eventCount) {
    }

    public record UserListRow(
            long id,
            String username,
            OffsetDateTime createdAt,
            boolean disabled,
            long deviceCount,
            OffsetDateTime lastActiveAt,
            boolean online,
            long todayTokens,
            double todayCredits,
            long weekTokens,
            double weekCredits) {
    }

    public record UserDetailRow(
            long id,
            String username,
            OffsetDateTime createdAt,
            boolean disabled,
            long deviceCount,
            OffsetDateTime lastActiveAt,
            boolean online,
            long todayTokens,
            double todayCredits,
            long weekTokens,
            double weekCredits,
            List<DeviceView> devices) {
    }

    private final UserRepository users;
    private final AdminConsoleRepository console;

    public AdminUserController(UserRepository users, AdminConsoleRepository console) {
        this.users = users;
        this.console = console;
    }

    @PostMapping
    public UserRepository.UserView create(@Valid @RequestBody CreateUserRequest request) {
        String username = request.username().trim();
        try {
            UserRepository.User user = users.create(username, AuthTokens.hashPassword(request.password()));
            return new UserRepository.UserView(
                    user.id(), user.username(), user.createdAt(), 0, user.disabled());
        } catch (DuplicateKeyException e) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "用户名已存在: " + username);
        }
    }

    @GetMapping
    public List<UserListRow> list() {
        OffsetDateTime now = AdminTimes.now();
        OffsetDateTime todayStart = AdminTimes.startOfDay(now.toLocalDate());
        OffsetDateTime weekStart = AdminTimes.daysStart(7);
        OffsetDateTime onlineSince = now.minusMinutes(AdminTimes.ONLINE_MINUTES);
        return console.findAllUsers(todayStart, weekStart, now).stream()
                .map(row -> toListRow(row, onlineSince))
                .toList();
    }

    @GetMapping("/{id}")
    public UserDetailRow detail(@PathVariable long id) {
        OffsetDateTime now = AdminTimes.now();
        OffsetDateTime todayStart = AdminTimes.startOfDay(now.toLocalDate());
        OffsetDateTime weekStart = AdminTimes.daysStart(7);
        OffsetDateTime onlineSince = now.minusMinutes(AdminTimes.ONLINE_MINUTES);
        AdminConsoleRepository.AdminUserRow row = console.findUser(id, todayStart, weekStart, now);
        if (row == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "用户不存在: " + id);
        }
        List<DeviceView> devices = console.findUserDevices(id).stream()
                .map(device -> toDeviceView(device, onlineSince))
                .toList();
        return new UserDetailRow(
                row.id(), row.username(), row.createdAt(), row.disabled(), row.deviceCount(),
                row.lastActiveAt(), isOnline(row.lastActiveAt(), onlineSince),
                row.todayTokens(), row.todayCredits(), row.weekTokens(), row.weekCredits(), devices);
    }

    @GetMapping("/{id}/devices")
    public List<DeviceView> devices(@PathVariable long id) {
        OffsetDateTime onlineSince = AdminTimes.onlineSince();
        return console.findUserDevices(id).stream()
                .map(device -> toDeviceView(device, onlineSince))
                .toList();
    }

    @PostMapping("/{id}/password")
    public void resetPassword(@PathVariable long id, @Valid @RequestBody ResetPasswordRequest request) {
        if (!users.updatePassword(id, AuthTokens.hashPassword(request.password()))) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "用户不存在: " + id);
        }
        // 改密后让旧会话全部失效，客户端需重新登录
        users.deleteTokens(id);
    }

    @PostMapping("/{id}/status")
    public void updateStatus(@PathVariable long id, @Valid @RequestBody StatusRequest request) {
        if (!users.setDisabled(id, request.disabled())) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "用户不存在: " + id);
        }
        if (request.disabled()) {
            users.deleteTokens(id);
        }
    }

    private UserListRow toListRow(AdminConsoleRepository.AdminUserRow row, OffsetDateTime onlineSince) {
        return new UserListRow(
                row.id(), row.username(), row.createdAt(), row.disabled(), row.deviceCount(),
                row.lastActiveAt(), isOnline(row.lastActiveAt(), onlineSince),
                row.todayTokens(), row.todayCredits(), row.weekTokens(), row.weekCredits());
    }

    private DeviceView toDeviceView(AdminConsoleRepository.DeviceRow device, OffsetDateTime onlineSince) {
        return new DeviceView(
                device.deviceId(),
                device.firstSeenAt(),
                device.lastSeenAt(),
                isOnline(device.lastSeenAt(), onlineSince),
                device.eventCount());
    }

    private static boolean isOnline(OffsetDateTime lastSeenAt, OffsetDateTime onlineSince) {
        return lastSeenAt != null && !lastSeenAt.isBefore(onlineSince);
    }
}

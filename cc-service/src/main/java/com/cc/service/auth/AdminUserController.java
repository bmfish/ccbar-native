package com.cc.service.auth;

import java.util.List;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
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

/** 用户管理（仅管理 Token 可访问），用 curl/脚本维护。 */
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

    private final UserRepository users;

    public AdminUserController(UserRepository users) {
        this.users = users;
    }

    @PostMapping
    public UserRepository.UserView create(@Valid @RequestBody CreateUserRequest request) {
        String username = request.username().trim();
        try {
            UserRepository.User user = users.create(username, AuthTokens.hashPassword(request.password()));
            return new UserRepository.UserView(user.id(), user.username(), user.createdAt(), 0);
        } catch (DuplicateKeyException e) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "用户名已存在: " + username);
        }
    }

    @GetMapping
    public List<UserRepository.UserView> list() {
        return users.findAll();
    }

    @PostMapping("/{id}/password")
    public void resetPassword(@PathVariable long id, @Valid @RequestBody ResetPasswordRequest request) {
        if (!users.updatePassword(id, AuthTokens.hashPassword(request.password()))) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "用户不存在: " + id);
        }
        // 改密后让旧会话全部失效，客户端需重新登录
        users.deleteTokens(id);
    }

    @GetMapping("/{id}/devices")
    public List<UserRepository.DeviceView> devices(@PathVariable long id) {
        UserRepository.UserView user = users.findAll().stream()
                .filter(item -> item.id() == id)
                .findFirst()
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "用户不存在: " + id));
        return users.findDevices(user.id());
    }
}

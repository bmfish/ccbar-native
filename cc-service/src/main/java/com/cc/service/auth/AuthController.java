package com.cc.service.auth;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

/** 用户名密码登录，成功后返回会话 Token（仅返回一次，服务端只存哈希）。 */
@RestController
@RequestMapping("/api/auth")
public class AuthController {

    public record LoginRequest(
            @NotBlank @Size(max = 64) String username,
            @NotBlank @Size(max = 200) String password) {
    }

    public record LoginResponse(String token, long userId, String username) {
    }

    private final UserRepository users;

    public AuthController(UserRepository users) {
        this.users = users;
    }

    @PostMapping("/login")
    public LoginResponse login(@Valid @RequestBody LoginRequest request) {
        String username = request.username().trim();
        UserRepository.User user = users.findByUsername(username)
                .orElseThrow(this::unauthorized);
        if (!AuthTokens.verifyPassword(request.password(), user.passwordHash())) {
            throw unauthorized();
        }
        String token = AuthTokens.newToken();
        users.saveToken(user.id(), AuthTokens.sha256Hex(token));
        return new LoginResponse(token, user.id(), user.username());
    }

    private ResponseStatusException unauthorized() {
        return new ResponseStatusException(HttpStatus.UNAUTHORIZED, "用户名或密码错误");
    }
}

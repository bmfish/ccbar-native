package com.cc.service.push;

import java.util.List;

import jakarta.validation.Valid;

import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** 管理端推送任务接口。 */
@RestController
@RequestMapping("/api/admin/push/tasks")
public class PushController {

    private final PushService pushService;

    public PushController(PushService pushService) {
        this.pushService = pushService;
    }

    @GetMapping
    public List<PushTask> list() {
        return pushService.list();
    }

    @PostMapping
    public PushTask create(@Valid @RequestBody PushTaskRequest request) {
        return pushService.create(request);
    }

    @PutMapping("/{id}")
    public PushTask update(@PathVariable long id, @Valid @RequestBody PushTaskRequest request) {
        return pushService.update(id, request);
    }

    @DeleteMapping("/{id}")
    public Boolean delete(@PathVariable long id) {
        pushService.delete(id);
        return true;
    }

    @PostMapping("/{id}/test")
    public PushResult test(@PathVariable long id) {
        return pushService.test(id);
    }
}

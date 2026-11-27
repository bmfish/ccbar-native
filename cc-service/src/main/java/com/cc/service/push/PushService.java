package com.cc.service.push;

import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import java.util.stream.Collectors;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;
import org.springframework.web.server.ResponseStatusException;

import com.cc.service.admin.AdminTimes;
import com.cc.service.push.content.PushContentGenerator;

/** 推送任务的增删改查、手动测试与定时检查。 */
@Service
public class PushService {

    private static final Logger log = LoggerFactory.getLogger(PushService.class);
    private static final int MAX_ERROR_LENGTH = 500;
    private static final Set<String> TASK_TYPES =
            Set.of(PushTask.TEXT, PushTask.WEIGHT, PushTask.TOKEN_USAGE);

    private final PushTaskRepository repository;
    private final BarkClient barkClient;
    private final Map<String, PushContentGenerator> generators;

    public PushService(
            PushTaskRepository repository,
            BarkClient barkClient,
            List<PushContentGenerator> generators) {
        this.repository = repository;
        this.barkClient = barkClient;
        this.generators = generators.stream()
                .collect(Collectors.toUnmodifiableMap(PushContentGenerator::taskType, Function.identity()));
    }

    public List<PushTask> list() {
        return repository.findAll();
    }

    public synchronized PushTask create(PushTaskRequest request) {
        String scheduleType = validateSchedule(request);
        String taskType = validateTaskType(request);
        long id = repository.create(request, scheduleType, taskType);
        return get(id);
    }

    public synchronized PushTask update(long id, PushTaskRequest request) {
        String scheduleType = validateSchedule(request);
        String taskType = validateTaskType(request);
        if (!repository.update(id, request, scheduleType, taskType)) {
            throw notFound(id);
        }
        return get(id);
    }

    public synchronized void delete(long id) {
        if (!repository.delete(id)) {
            throw notFound(id);
        }
    }

    /** 立即推送一条任务，不受启用状态和调度时间限制。 */
    public synchronized PushResult test(long id) {
        PushTask task = get(id);
        validateBarkUrl(task.barkUrl());
        return attempt(task, AdminTimes.now());
    }

    /** 定时器每 30 秒调用一次，逐个检查启用的任务。 */
    public synchronized void tick() {
        OffsetDateTime now = AdminTimes.now();
        for (PushTask task : repository.findEnabled()) {
            if (!isDue(task, now)) {
                continue;
            }
            PushResult result = attempt(task, now);
            if (result.success()) {
                log.info("推送任务已发送: {}", task.name());
            } else {
                log.warn("推送任务发送失败: {} - {}", task.name(), result.message());
            }
        }
    }

    /**
     * 事件式推送（如新票根提醒）：直接发往所有启用任务的 Bark 地址（去重），
     * 不占用任务调度、不写任务的 lastSentAt。返回成功发送的地址数。
     */
    public synchronized int sendEventNotification(String title, String body, String group) {
        Set<String> urls = repository.findEnabled().stream()
                .map(PushTask::barkUrl)
                .filter(StringUtils::hasText)
                .map(String::trim)
                .collect(Collectors.toSet());
        if (urls.isEmpty()) {
            log.info("事件推送「{}」跳过：没有启用的推送任务", title);
            return 0;
        }
        int sent = 0;
        for (String url : urls) {
            try {
                barkClient.sendToUrl(url, title, body, group);
                sent++;
            } catch (Exception exception) {
                log.warn("事件推送「{}」发送失败: {}", title, messageOf(exception));
            }
        }
        log.info("事件推送「{}」已发送 {}/{} 个设备", title, sent, urls.size());
        return sent;
    }

    static boolean isDue(PushTask task, OffsetDateTime now) {
        if (!task.enabled() || !StringUtils.hasText(task.barkUrl())) {
            return false;
        }
        if (PushTask.DAILY.equals(task.scheduleType())) {
            if (task.dailyTime() == null || now.toLocalTime().isBefore(task.dailyTime())) {
                return false;
            }
            if (task.lastSentAt() == null) {
                return true;
            }
            LocalDate lastSentDate = task.lastSentAt()
                    .atZoneSameInstant(AdminTimes.ZONE).toLocalDate();
            return lastSentDate.isBefore(now.toLocalDate());
        }
        if (!inWindow(task.activeStart(), task.activeEnd(), now.toLocalTime())) {
            return false;
        }
        return task.lastSentAt() == null
                || !now.isBefore(task.lastSentAt().plusMinutes(task.intervalMinutes()));
    }

    private static boolean inWindow(LocalTime start, LocalTime end, LocalTime time) {
        if (start.equals(end)) {
            return true;
        }
        if (start.isBefore(end)) {
            return !time.isBefore(start) && time.isBefore(end);
        }
        return !time.isBefore(start) || time.isBefore(end);
    }

    private PushResult attempt(PushTask task, OffsetDateTime now) {
        String status = "SUCCESS";
        String error = "";
        String body = "";
        try {
            PushContentGenerator generator = generators.getOrDefault(
                    normalizeType(task.taskType()), generators.get(PushTask.TEXT));
            body = generator.generate(task, now);
            barkClient.send(task, body);
        } catch (Exception exception) {
            status = "FAILED";
            error = truncate(messageOf(exception), MAX_ERROR_LENGTH);
        }
        repository.markResult(task.id(), now, status, error, body);
        boolean success = "SUCCESS".equals(status);
        return new PushResult(success, success ? "推送成功" : "推送失败: " + error, now);
    }

    private String validateSchedule(PushTaskRequest request) {
        String type = request.scheduleType() == null
                ? "" : request.scheduleType().trim().toUpperCase(Locale.ROOT);
        if (!PushTask.INTERVAL.equals(type) && !PushTask.DAILY.equals(type)) {
            throw badRequest("调度方式必须是 INTERVAL 或 DAILY");
        }
        if (PushTask.INTERVAL.equals(type) && request.intervalMinutes() == null) {
            throw badRequest("间隔推送必须填写间隔分钟数");
        }
        if (PushTask.DAILY.equals(type) && request.dailyTime() == null) {
            throw badRequest("每天定时推送必须填写推送时间");
        }
        return type;
    }

    private String validateTaskType(PushTaskRequest request) {
        if (!StringUtils.hasText(request.name()) || !StringUtils.hasText(request.title())) {
            throw badRequest("任务名称和标题不能为空");
        }
        if (!StringUtils.hasText(request.barkUrl())) {
            throw badRequest("Bark 地址不能为空");
        }
        validateBarkUrl(request.barkUrl());

        String type = normalizeType(request.taskType());
        if (!TASK_TYPES.contains(type)) {
            throw badRequest("任务类型必须是 TEXT、WEIGHT 或 TOKEN_USAGE");
        }
        if (PushTask.TEXT.equals(type) && !StringUtils.hasText(request.messages())) {
            throw badRequest("静态文案任务必须填写推送内容");
        }
        return type;
    }

    private static String normalizeType(String taskType) {
        return StringUtils.hasText(taskType)
                ? taskType.trim().toUpperCase(Locale.ROOT)
                : PushTask.TEXT;
    }

    private void validateBarkUrl(String barkUrl) {
        String value = barkUrl.trim().toLowerCase(Locale.ROOT);
        if (!value.startsWith("http://") && !value.startsWith("https://")) {
            throw badRequest("Bark 地址必须以 http:// 或 https:// 开头");
        }
    }

    private PushTask get(long id) {
        return repository.findById(id).orElseThrow(() -> notFound(id));
    }

    private static ResponseStatusException notFound(long id) {
        return new ResponseStatusException(HttpStatus.NOT_FOUND, "推送任务不存在: " + id);
    }

    private static ResponseStatusException badRequest(String message) {
        return new ResponseStatusException(HttpStatus.BAD_REQUEST, message);
    }

    private static String messageOf(Exception exception) {
        String message = exception.getMessage();
        return StringUtils.hasText(message) ? message : exception.getClass().getSimpleName();
    }

    private static String truncate(String value, int maxLength) {
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }
}

package com.cc.service.settings;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.core.env.Environment;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

import com.cc.service.admin.TtlCache;

/**
 * 运行时设置中枢：数据库值优先，环境变量兜底，最后是代码默认值。
 *
 * <p>管理台「系统设置」页通过 {@link #sections()} 拿到字段定义，保存后 {@link #save} 直写数据库并清缓存，
 * 消费方（LLM 客户端、邮件同步引擎）每次使用前现读，改完即生效、无需重启。</p>
 */
@Service
public class AppSettings {

    // ---------- LLM ----------
    public static final String LLM_BASE_URL = "llm.base-url";
    public static final String LLM_API_KEY = "llm.api-key";
    public static final String LLM_MODEL = "llm.model";
    public static final String LLM_THINKING = "llm.thinking";
    public static final String LLM_TIMEOUT_MS = "llm.timeout-ms";
    public static final String LLM_MAX_ATTEMPTS = "llm.max-attempts";

    // ---------- 12306 邮件同步 ----------
    public static final String TRAVEL_ENABLED = "travel.enabled";
    public static final String TRAVEL_MAIL_HOST = "travel.mail.host";
    public static final String TRAVEL_MAIL_PORT = "travel.mail.port";
    public static final String TRAVEL_MAIL_EMAIL = "travel.mail.email";
    public static final String TRAVEL_MAIL_AUTH_CODE = "travel.mail.auth-code";
    public static final String TRAVEL_MAIL_OWNER = "travel.mail.owner";
    public static final String TRAVEL_MIN_INTERVAL_MINUTES = "travel.min-interval-minutes";

    /** 字段类型：text 文本 / password 密钥（回显掩码）/ boolean 开关 / number 数字。 */
    public record FieldDef(String key, String label, String type, boolean secret, String hint) {
    }

    public record SectionDef(String id, String title, String description, List<FieldDef> fields) {
    }

    private static final List<SectionDef> SECTIONS = List.of(
            new SectionDef("llm", "AI 分析（智谱 GLM）",
                    "体重等数据的 AI 解读。兼容 OpenAI 格式，换厂商改接口地址与模型即可。免费模型高峰期可能限流，服务端已自动重试。",
                    List.of(
                            new FieldDef(LLM_BASE_URL, "接口地址", "text", false, "OpenAI 兼容 base-url"),
                            new FieldDef(LLM_API_KEY, "API Key", "password", true,
                                    "bigmodel.cn 控制台生成，两段式（含点号）"),
                            new FieldDef(LLM_MODEL, "模型", "text", false, "如 glm-4.7-flash（免费）"),
                            new FieldDef(LLM_THINKING, "深度思考", "boolean", false, "开启后更准但更慢，分析场景建议关"),
                            new FieldDef(LLM_TIMEOUT_MS, "读超时（毫秒）", "number", false, "LLM 生成较慢，建议 ≥60000"),
                            new FieldDef(LLM_MAX_ATTEMPTS, "失败重试次数", "number", false, "限流 1305 自动退避重试"))),
            new SectionDef("mail", "12306 邮件同步（QQ 邮箱）",
                    "IMAP 拉取 12306 订票邮件并解析为车票。授权码在 QQ 邮箱设置 → 账户 → 开启 IMAP 后生成（16 位，非登录密码）。",
                    List.of(
                            new FieldDef(TRAVEL_ENABLED, "自动同步开关", "boolean", false, "关闭后仅能手动触发同步"),
                            new FieldDef(TRAVEL_MAIL_HOST, "IMAP 服务器", "text", false, "QQ 邮箱为 imap.qq.com"),
                            new FieldDef(TRAVEL_MAIL_PORT, "IMAP 端口", "number", false, "SSL 端口 993；8025 走明文（联调）"),
                            new FieldDef(TRAVEL_MAIL_EMAIL, "邮箱账号", "text", false, "完整邮箱地址"),
                            new FieldDef(TRAVEL_MAIL_AUTH_CODE, "授权码", "password", true, "只落库，界面回显掩码"),
                            new FieldDef(TRAVEL_MAIL_OWNER, "乘车人姓名", "text", false, "只导入本人车票，留空不过滤"),
                            new FieldDef(TRAVEL_MIN_INTERVAL_MINUTES, "同步节流（分钟）", "number", false, "距上次成功同步不足该分钟数则跳过自动同步"))));

    private static final long CACHE_TTL_MS = 30_000;

    private final AppSettingRepository repository;
    private final Environment environment;
    private final TtlCache<String, String> cache = new TtlCache<>(CACHE_TTL_MS);

    public AppSettings(AppSettingRepository repository, Environment environment) {
        this.repository = repository;
        this.environment = environment;
    }

    public List<SectionDef> sections() {
        return SECTIONS;
    }

    /** 生效值：数据库 > 环境变量（含 application.yml 默认） > 空串。 */
    public String get(String key) {
        String cached = cache.get(key, () -> repository.findAll().get(key));
        if (StringUtils.hasText(cached)) {
            return cached.trim();
        }
        String fromEnv = environment.getProperty(envProperty(key));
        return fromEnv == null ? "" : fromEnv.trim();
    }

    public boolean getBool(String key) {
        return "true".equalsIgnoreCase(get(key));
    }

    public int getInt(String key, int fallback) {
        try {
            return Integer.parseInt(get(key));
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }

    /** 值来源：db（管理台保存）/ env（环境变量或 yml）/ default（未配置）。 */
    public String source(String key) {
        if (StringUtils.hasText(repository.findAll().get(key))) {
            return "db";
        }
        return StringUtils.hasText(environment.getProperty(envProperty(key))) ? "env" : "default";
    }

    /** 密钥回显掩码：只保留末 4 位。 */
    public String masked(String key) {
        String value = get(key);
        if (!StringUtils.hasText(value)) {
            return "";
        }
        int keep = Math.min(4, Math.max(value.length() - 4, 0));
        return "••••••" + value.substring(value.length() - keep);
    }

    /** 保存一批值；密钥字段传空串表示不修改。非法 key 直接拒绝。 */
    public void save(Map<String, String> values) {
        for (Map.Entry<String, String> entry : values.entrySet()) {
            FieldDef def = fieldDef(entry.getKey());
            if (def == null) {
                throw new IllegalArgumentException("不支持的设置项: " + entry.getKey());
            }
            String value = entry.getValue() == null ? "" : entry.getValue().trim();
            if (def.secret() && !StringUtils.hasText(value)) {
                continue;
            }
            repository.save(def.key(), value);
        }
        cache.clear();
    }

    public FieldDef fieldDef(String key) {
        for (SectionDef section : SECTIONS) {
            for (FieldDef field : section.fields()) {
                if (field.key().equals(key)) {
                    return field;
                }
            }
        }
        return null;
    }

    /** 当前展示视图：值 + 来源 + 掩码，供管理台渲染。 */
    public Map<String, Object> view() {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("sections", SECTIONS);
        Map<String, Object> fields = new LinkedHashMap<>();
        for (SectionDef section : SECTIONS) {
            for (FieldDef field : section.fields()) {
                Map<String, Object> state = new LinkedHashMap<>();
                state.put("value", field.secret() ? masked(field.key()) : get(field.key()));
                state.put("hasValue", StringUtils.hasText(get(field.key())));
                state.put("source", source(field.key()));
                fields.put(field.key(), state);
            }
        }
        payload.put("fields", fields);
        return payload;
    }

    /** key "llm.api-key" → spring 属性 "app.llm.api-key"（环境变量经 application.yml 占位符解出）。 */
    private String envProperty(String key) {
        return "app." + key;
    }
}

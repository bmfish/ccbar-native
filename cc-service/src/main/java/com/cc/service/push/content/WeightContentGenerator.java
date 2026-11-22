package com.cc.service.push.content;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Locale;

import org.springframework.stereotype.Component;

import com.cc.service.admin.AdminTimes;
import com.cc.service.health.HealthSample;
import com.cc.service.health.HealthSampleRepository;
import com.cc.service.push.PushTask;

/** 体重：今天已称重就播报体重和变化，还没称就提醒上秤。 */
@Component
public class WeightContentGenerator implements PushContentGenerator {

    private static final DateTimeFormatter MONTH_DAY = DateTimeFormatter.ofPattern("M月d日", Locale.CHINA);

    private final HealthSampleRepository healthSamples;

    public WeightContentGenerator(HealthSampleRepository healthSamples) {
        this.healthSamples = healthSamples;
    }

    @Override
    public String taskType() {
        return PushTask.WEIGHT;
    }

    @Override
    public String generate(PushTask task, OffsetDateTime now) {
        List<HealthSample> samples = healthSamples.find("weight", null, null, 2);
        if (samples.isEmpty()) {
            String fallback = randomFallback(task);
            return fallback != null ? fallback : "还没有体重记录，先上秤称一次吧。";
        }

        HealthSample current = samples.get(0);
        LocalDate today = now.atZoneSameInstant(AdminTimes.ZONE).toLocalDate();
        LocalDate recordedDate = current.recordedAt().atZoneSameInstant(AdminTimes.ZONE).toLocalDate();
        if (!recordedDate.equals(today)) {
            return "今天还没称体重，上次是 " + recordedDate.format(MONTH_DAY)
                    + " 的 " + kg(current.value()) + " kg，记得上秤记录一下。";
        }

        StringBuilder message = new StringBuilder("今日体重 ").append(kg(current.value())).append(" kg");
        if (samples.size() > 1) {
            double delta = current.value() - samples.get(1).value();
            if (Math.abs(delta) >= 0.05) {
                message.append("，较上次 ").append(String.format(Locale.ROOT, "%+.1f", delta)).append(" kg");
            }
        }
        return message.append("。").toString();
    }

    private static String kg(double value) {
        return String.format(Locale.ROOT, "%.1f", value);
    }
}

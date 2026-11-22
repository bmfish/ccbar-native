package com.cc.service.push.content;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Locale;
import java.util.Map;

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
            return MessageTemplates.pick(task, "无数据", Map.of(),
                    "还没有体重记录，先上秤称一次吧。");
        }

        HealthSample current = samples.get(0);
        LocalDate today = now.atZoneSameInstant(AdminTimes.ZONE).toLocalDate();
        LocalDate recordedDate = current.recordedAt().atZoneSameInstant(AdminTimes.ZONE).toLocalDate();
        if (!recordedDate.equals(today)) {
            return MessageTemplates.pick(task, "未称",
                    Map.of(
                            "lastDate", recordedDate.format(MONTH_DAY),
                            "lastWeight", kg(current.value())),
                    "今天还没称体重，上次是 {lastDate} 的 {lastWeight} kg，记得上秤记录一下。");
        }

        if (samples.size() < 2) {
            return MessageTemplates.pick(task, "已称-无对比",
                    Map.of("weight", kg(current.value())),
                    "今日体重 {weight} kg。");
        }

        HealthSample previous = samples.get(1);
        double delta = current.value() - previous.value();
        String deltaText;
        String deltaPhrase;
        if (Math.abs(delta) < 0.05) {
            deltaText = "没有变化";
            deltaPhrase = "没有变化";
        } else if (delta > 0) {
            deltaText = String.format(Locale.ROOT, "%+.1f kg", delta);
            deltaPhrase = "增加了 " + kg(delta) + " kg";
        } else {
            deltaText = String.format(Locale.ROOT, "%.1f kg", delta);
            deltaPhrase = "减少了 " + kg(-delta) + " kg";
        }

        return MessageTemplates.pick(task, "已称",
                Map.of(
                        "weight", kg(current.value()),
                        "delta", deltaText,
                        "deltaPhrase", deltaPhrase,
                        "lastWeight", kg(previous.value())),
                "今日体重 {weight} kg，较上次 {delta}。");
    }

    private static String kg(double value) {
        return String.format(Locale.ROOT, "%.1f", value);
    }
}

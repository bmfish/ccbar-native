package com.cc.service.push;

import java.net.URI;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;
import org.springframework.web.util.UriComponentsBuilder;

/** 调用 Bark 的 GET 推送接口。 */
@Component
public class BarkClient {

    private final RestClient client;
    private final ObjectMapper objectMapper;

    public BarkClient(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(5000);
        factory.setReadTimeout(8000);
        this.client = RestClient.builder().requestFactory(factory).build();
    }

    public void send(PushTask task, String message) {
        sendToUrl(task.barkUrl(), task.title(), message, task.groupName());
    }

    /** 事件式推送：直接按 Bark 地址发送，不经过推送任务调度。 */
    public void sendToUrl(String barkUrl, String title, String message, String group) {
        URI uri = buildUri(barkUrl, title, message, group);
        try {
            String response = client.get().uri(uri).retrieve().body(String.class);
            if (response == null || response.isBlank()) {
                return;
            }
            var node = objectMapper.readTree(response);
            int code = node.path("code").asInt(200);
            if (code != 200) {
                throw new IllegalStateException("Bark 返回 " + code + ": "
                        + node.path("message").asText(""));
            }
        } catch (RestClientResponseException exception) {
            throw new IllegalStateException("Bark HTTP " + exception.getStatusCode().value()
                    + ": " + truncate(exception.getResponseBodyAsString(), 200), exception);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("Bark 响应解析失败", exception);
        }
    }

    private URI buildUri(String barkUrl, String title, String message, String group) {
        String base = barkUrl.trim();
        while (base.endsWith("/")) {
            base = base.substring(0, base.length() - 1);
        }
        var builder = UriComponentsBuilder.fromUriString(base)
                .pathSegment(title, message);
        if (StringUtils.hasText(group)) {
            builder.queryParam("group", group);
        }
        return builder.build().encode().toUri();
    }

    private static String truncate(String value, int maxLength) {
        if (value == null) {
            return "";
        }
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }
}

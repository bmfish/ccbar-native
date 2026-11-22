package com.cc.service.health;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/api/health/samples")
public class HealthDataController {

    private static final Set<String> KINDS = Set.of("weight", "bodyfat", "height");
    private static final int MAX_BATCH = 5000;

    /** kind: weight（kg）/ bodyfat（0~1）/ height（cm） */
    public record SamplePayload(
            @NotBlank String kind,
            @NotNull OffsetDateTime recordedAt,
            @NotNull Double value,
            @Size(max = 100) String source) {
    }

    public record SyncRequest(@NotEmpty @Size(max = MAX_BATCH) List<@Valid SamplePayload> samples) {
    }

    public record SyncResult(int received, int saved) {
    }

    private final HealthSampleRepository repository;

    public HealthDataController(HealthSampleRepository repository) {
        this.repository = repository;
    }

    @PostMapping
    public SyncResult sync(@Valid @RequestBody SyncRequest request) {
        List<HealthSampleRepository.HealthSampleInput> inputs = request.samples().stream()
                .map(this::toInput)
                .toList();
        return new SyncResult(inputs.size(), repository.upsertAll(inputs));
    }

    @GetMapping
    public List<HealthSample> list(
            @RequestParam(required = false) String kind,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime to,
            @RequestParam(defaultValue = "1000") int limit) {
        if (kind != null && !KINDS.contains(kind)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "unsupported kind: " + kind);
        }
        return repository.find(kind, from, to, Math.min(Math.max(limit, 1), MAX_BATCH));
    }

    private HealthSampleRepository.HealthSampleInput toInput(SamplePayload payload) {
        String kind = payload.kind().trim().toLowerCase();
        if (!KINDS.contains(kind)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "unsupported kind: " + payload.kind());
        }
        double value = payload.value();
        if (!Double.isFinite(value)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "value must be finite");
        }
        return new HealthSampleRepository.HealthSampleInput(kind, payload.recordedAt(), value, payload.source());
    }
}

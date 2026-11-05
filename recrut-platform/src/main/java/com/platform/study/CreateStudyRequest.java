package com.platform.study;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Positive;

public record CreateStudyRequest(
        @NotBlank String title,
        @Min(15) @Max(240) int sessionDurationMin,
        @Positive int targetN) {
}

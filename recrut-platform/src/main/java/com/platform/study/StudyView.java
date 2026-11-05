package com.platform.study;

import java.util.UUID;

public record StudyView(
        UUID id,
        String title,
        String status,
        int sessionDurationMin,
        int targetN) {
}

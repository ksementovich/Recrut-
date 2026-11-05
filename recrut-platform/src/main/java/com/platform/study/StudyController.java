package com.platform.study;

import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * ВНИМАНИЕ: контекст (X-Org-Id, X-User-Id) берётся из заголовков только для разработки.
 * До продакшена заменить на Spring Security: организация и пользователь должны приходить
 * из проверенного токена, а принадлежность пользователя организации — проверяться по membership.
 */
@RestController
@RequestMapping("/api/v1/studies")
public class StudyController {

    private final StudyService studies;

    public StudyController(StudyService studies) {
        this.studies = studies;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public StudyView create(@RequestHeader("X-Org-Id") UUID orgId,
                            @RequestHeader("X-User-Id") UUID userId,
                            @Valid @RequestBody CreateStudyRequest body) {
        return studies.create(orgId, userId, body);
    }

    @GetMapping
    public List<StudyView> list(@RequestHeader("X-Org-Id") UUID orgId) {
        return studies.list(orgId);
    }
}

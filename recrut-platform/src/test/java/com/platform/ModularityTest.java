package com.platform;

import org.junit.jupiter.api.Test;
import org.springframework.modulith.core.ApplicationModules;

/**
 * Проверяет границы модулей: модуль не импортирует внутренние классы другого модуля.
 * Модули: shared, audit, budget, study (см. раздел 3.1 архитектуры).
 */
class ModularityTest {

    @Test
    void moduleBoundariesAreRespected() {
        ApplicationModules.of(PlatformApplication.class).verify();
    }
}

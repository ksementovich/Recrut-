# recrut-platform — скелет MVP

Реализация первой части архитектуры из `Architecture-and-UX.md`: фундамент, RLS, ledger бюджета, модуль исследований.

## Что внутри

| Путь | Что это | Статус проверки |
|---|---|---|
| `src/main/resources/db/migration/V1__foundation.sql` | Схема: организации, membership, study, budget ledger, session + session_moderator (exclusion), outbox, audit (append-only), RLS на всех тенант-таблицах | **Применена и проверена** на PostgreSQL 16 |
| `db/roles.sql` | Роль приложения `app_rt` (не владелец, без BYPASSRLS) и гранты | **Применена и проверена** |
| `db/tests/invariants.sql` | 8 групп проверок инвариантов: изоляция RLS, WITH CHECK, условный резерв, CHECK бюджета, exclusion с буферами, append-only аудит | **Все проверки проходят** (10 утверждений) |
| `src/main/java/com/platform/budget/` | `BudgetService.reserve`: условный UPDATE, идемпотентность, откат всей операции при отказе | Написано, **не компилировалось** |
| `src/main/java/com/platform/study/` | Создание и список исследований с RLS и записью аудита | Написано, **не компилировалось** |
| `src/main/java/com/platform/audit/`, `shared/` | `AuditRecorder`, `Tenant.bind` (set_config в транзакции) | Написано, **не компилировалось** |
| `src/test/java/com/platform/ModularityTest.java` | Spring Modulith: проверка границ модулей | Написано, **не запускалось** |

## Что изменено относительно документа (по итогам ревью)

- **Booking:** exclusion-ограничение перенесено с `session.moderator_id` на `session_moderator`, где модераторов может быть несколько. Буферы учитываются в колонке `busy` (интервал), которую считает приложение.
- **RLS:** добавлены `WITH CHECK` (нельзя вставить строку в чужую организацию) и `FORCE ROW LEVEL SECURITY` (политика действует и на владельца таблицы).
- **Бюджет:** добавлен CHECK `reserved + spent <= limit` как страховка на уровне БД.

## Что не сделано

- **Аутентификация.** Контекст организации берётся из заголовков `X-Org-Id` и `X-User-Id`. Это заглушка для разработки. Нужен Spring Security с проверкой membership.
- **Права по матрице из PRD.** Не реализованы, нужна модель permissions.
- **Outbox-воркер, Google Ads, Calendar, email.** Таблица `outbox_event` есть, обработчиков нет.
- **Публичный путь кандидата и фронтенд.** Не начаты.
- **Java-тесты.** Не запускались. Нужны Testcontainers (Docker) и доступ к Maven Central.

## Как запустить

### 1. База данных

```bash
createdb recrut
# от владельца схемы (роль recrut_owner)
psql -d recrut -f src/main/resources/db/migration/V1__foundation.sql
# от администратора, один раз на окружение
psql -d recrut -f db/roles.sql
# проверки инвариантов (от суперпользователя, на пустой БД)
psql -d recrut -v ON_ERROR_STOP=1 -f db/tests/invariants.sql
```

### 2. Приложение

```bash
export DB_URL=jdbc:postgresql://localhost:5432/recrut
export DB_APP_PASSWORD=...        # пароль app_rt
export DB_OWNER_USER=recrut_owner
export DB_OWNER_PASSWORD=...
mvn spring-boot:run
```

Пример запроса:

```bash
curl -X POST localhost:8080/api/v1/studies \
  -H 'Content-Type: application/json' \
  -H 'X-Org-Id: 00000000-0000-0000-0000-00000000000a' \
  -H 'X-User-Id: 00000000-0000-0000-0000-0000000000a1' \
  -d '{"title":"Интервью про онлайн-банкинг","sessionDurationMin":60,"targetN":15}'
```

## Версии, которые нужно проверить при первой сборке

- Spring Boot 3.3.5 и Spring Modulith 1.2.5 в `pom.xml`. Версию Modulith сверить с BOM, которая совместима с Boot 3.3.
- Версии Flyway и Testcontainers берутся из BOM Boot.

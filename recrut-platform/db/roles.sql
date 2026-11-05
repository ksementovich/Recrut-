-- Роли БД. Выполняется администратором один раз на окружение (не миграцией).
-- app_rt: роль приложения. Не владелец таблиц, не superuser, не BYPASSRLS -> RLS действует.
-- app_worker: фоновые задачи между организациями (outbox, сверка). Использование логируется.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rt') THEN
    CREATE ROLE app_rt LOGIN NOSUPERUSER NOBYPASSRLS;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO app_rt;

GRANT SELECT, INSERT, UPDATE, DELETE ON
  organization, app_user, membership, study,
  budget_account, budget_entry, outbox_event,
  session, session_moderator
TO app_rt;

-- audit_event: только INSERT и SELECT. UPDATE/DELETE отозваны, и есть триггер.
GRANT SELECT, INSERT ON audit_event TO app_rt;
GRANT USAGE ON SEQUENCE audit_event_id_seq TO app_rt;

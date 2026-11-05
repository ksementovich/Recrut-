-- Проверка инвариантов схемы на реальном PostgreSQL.
-- Запуск: psql -v ON_ERROR_STOP=1 -f db/tests/invariants.sql  (от суперпользователя, на пустой БД после миграций и roles.sql)
-- Каждый блок либо проходит, либо бросает исключение с понятным сообщением.

\set ON_ERROR_STOP on

-- ---------- подготовка (суперпользователь обходит RLS, это нормально для setup)
INSERT INTO organization (id, name) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Org A'),
  ('00000000-0000-0000-0000-00000000000b', 'Org B');

INSERT INTO app_user (id, email, name) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'mod1@example.com', 'Moderator 1'),
  ('00000000-0000-0000-0000-0000000000a2', 'mod2@example.com', 'Moderator 2');

INSERT INTO study (id, org_id, title, session_duration_min, target_n) VALUES
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', 'Study A', 60, 15);

INSERT INTO budget_account (id, org_id, scope_type, scope_id, currency, limit_amount) VALUES
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000000a', 'ORG', '00000000-0000-0000-0000-00000000000a', 'EUR', 100.00);

-- ---------- переключаемся на роль приложения: дальше действует RLS
SET ROLE app_rt;

-- T1: без контекста организации строки не видны
DO $$
BEGIN
  PERFORM set_config('app.org_id', '', true);
  IF (SELECT count(*) FROM study) <> 0 THEN
    RAISE EXCEPTION 'T1 FAIL: без app.org_id видны строки study';
  END IF;
  RAISE NOTICE 'T1 OK: пустой контекст не видит данные';
END
$$;

-- T2: организация B не видит study организации A
DO $$
BEGIN
  PERFORM set_config('app.org_id', '00000000-0000-0000-0000-00000000000b', true);
  IF (SELECT count(*) FROM study) <> 0 THEN
    RAISE EXCEPTION 'T2 FAIL: org B видит study org A';
  END IF;
  RAISE NOTICE 'T2 OK: изоляция чтения между организациями';
END
$$;

-- T3: организация B не может вставить строку с org_id = A (WITH CHECK)
DO $$
BEGIN
  PERFORM set_config('app.org_id', '00000000-0000-0000-0000-00000000000b', true);
  BEGIN
    INSERT INTO study (org_id, title, session_duration_min, target_n)
    VALUES ('00000000-0000-0000-0000-00000000000a', 'Hack', 60, 1);
    RAISE EXCEPTION 'T3 FAIL: вставка в чужую организацию прошла';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'T3 OK: вставка в чужую организацию отклонена RLS';
  END;
END
$$;

-- T4: условный резерв. Лимит 100, резерв 60 проходит, ещё 60 отклоняется (0 строк).
DO $$
DECLARE n int;
BEGIN
  PERFORM set_config('app.org_id', '00000000-0000-0000-0000-00000000000a', true);

  UPDATE budget_account
     SET reserved_amount = reserved_amount + 60, version = version + 1
   WHERE id = '00000000-0000-0000-0000-0000000000d1'
     AND limit_amount - reserved_amount - spent_amount >= 60;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'T4 FAIL: первый резерв должен пройти'; END IF;

  UPDATE budget_account
     SET reserved_amount = reserved_amount + 60, version = version + 1
   WHERE id = '00000000-0000-0000-0000-0000000000d1'
     AND limit_amount - reserved_amount - spent_amount >= 60;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'T4 FAIL: второй резерв сверх лимита не должен пройти'; END IF;

  RAISE NOTICE 'T4 OK: условный резерв не пропускает перерасход';
END
$$;

-- T5: CHECK-страховка. Прямой UPDATE мимо условия должен упасть на ограничении БД.
DO $$
BEGIN
  PERFORM set_config('app.org_id', '00000000-0000-0000-0000-00000000000a', true);
  BEGIN
    UPDATE budget_account SET reserved_amount = 500
     WHERE id = '00000000-0000-0000-0000-0000000000d1';
    RAISE EXCEPTION 'T5 FAIL: CHECK не сработал';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'T5 OK: CHECK reserved+spent<=limit держит инвариант';
  END;
END
$$;

-- T6: двойное бронирование модератора в пересекающихся интервалах (с буферами)
DO $$
DECLARE s1 uuid := '00000000-0000-0000-0000-0000000000e1';
        s2 uuid := '00000000-0000-0000-0000-0000000000e2';
BEGIN
  PERFORM set_config('app.org_id', '00000000-0000-0000-0000-00000000000a', true);

  INSERT INTO session (id, org_id, study_id, starts_at, ends_at)
  VALUES (s1, '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c1',
          '2026-12-01 10:00+01', '2026-12-01 11:00+01'),
         (s2, '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c1',
          '2026-12-01 11:10+01', '2026-12-01 12:10+01');

  -- сессия 1 занимает 09:45–11:15 (буфер 15 мин с обеих сторон)
  INSERT INTO session_moderator (session_id, org_id, moderator_id, busy)
  VALUES (s1, '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
          tstzrange('2026-12-01 09:45+01', '2026-12-01 11:15+01', '[)'));

  -- сессия 2 с 11:10 пересекается с занятостью сессии 1 -> должно упасть
  BEGIN
    INSERT INTO session_moderator (session_id, org_id, moderator_id, busy)
    VALUES (s2, '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
            tstzrange('2026-12-01 10:55+01', '2026-12-01 12:25+01', '[)'));
    RAISE EXCEPTION 'T6 FAIL: пересечение с буфером не поймано';
  EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'T6 OK: exclusion-ограничение ловит пересечение с буферами';
  END;

  -- другой модератор в то же время — разрешено
  INSERT INTO session_moderator (session_id, org_id, moderator_id, busy)
  VALUES (s2, '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2',
          tstzrange('2026-12-01 10:55+01', '2026-12-01 12:25+01', '[)'));
  RAISE NOTICE 'T6 OK: другой модератор в то же время разрешён';
END
$$;

-- T7: аудит append-only. UPDATE и DELETE запрещены.
DO $$
DECLARE aid bigint;
BEGIN
  PERFORM set_config('app.org_id', '00000000-0000-0000-0000-00000000000a', true);
  INSERT INTO audit_event (org_id, entity, entity_id, action, after_state)
  VALUES ('00000000-0000-0000-0000-00000000000a', 'study', 'x', 'CREATE', '{"title":"A"}')
  RETURNING id INTO aid;

  -- для app_rt UPDATE/DELETE отозваны грантами (первый слой), триггер — второй слой
  BEGIN
    UPDATE audit_event SET action = 'TAMPER' WHERE id = aid;
    RAISE EXCEPTION 'T7 FAIL: UPDATE аудита прошёл';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'T7 OK: UPDATE аудита запрещён грантами';
  END;

  BEGIN
    DELETE FROM audit_event WHERE id = aid;
    RAISE EXCEPTION 'T7 FAIL: DELETE аудита прошёл';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'T7 OK: DELETE аудита запрещён грантами';
  END;
END
$$;

RESET ROLE;

-- T8: триггер append-only срабатывает даже у владельца (без грантов)
DO $$
BEGIN
  BEGIN
    UPDATE audit_event SET action = 'TAMPER';
    RAISE EXCEPTION 'T8 FAIL: триггер не сработал';
  EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'T8 OK: триггер append-only держит второй слой';
  END;
END
$$;
\echo '=== все проверки пройдены ==='

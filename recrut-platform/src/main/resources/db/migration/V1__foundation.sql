-- V1: фундамент платформы (см. Architecture-and-UX.md, разделы 4.1, 4.3, 4.5, 4.9)
-- Миграции выполняются владельцем схемы (не app_rt). Роль приложения создаётся в db/roles.sql.

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------- организации и пользователи

CREATE TABLE organization (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(btrim(name)) > 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Глобальная таблица (не тенант-зависимая): один человек может состоять в нескольких организациях.
CREATE TABLE app_user (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email       text NOT NULL UNIQUE,
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE membership (
  org_id      uuid NOT NULL REFERENCES organization(id),
  user_id     uuid NOT NULL REFERENCES app_user(id),
  role        text NOT NULL CHECK (role IN ('OWNER','ADMIN','RESEARCHER','RECRUITER','COORDINATOR','MODERATOR')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, user_id)
);

-- ---------------------------------------------------------------- исследования

CREATE TABLE study (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id               uuid NOT NULL REFERENCES organization(id),
  title                text NOT NULL CHECK (length(btrim(title)) > 0),
  type                 text NOT NULL DEFAULT 'QUALITATIVE' CHECK (type IN ('QUALITATIVE')),
  status               text NOT NULL DEFAULT 'DRAFT'
                         CHECK (status IN ('DRAFT','RECRUITING','RECRUITMENT_CLOSED','IN_PROGRESS','COMPLETED','ARCHIVED')),
  session_duration_min int  NOT NULL CHECK (session_duration_min BETWEEN 15 AND 240),
  target_n             int  NOT NULL CHECK (target_n > 0),
  created_by           uuid REFERENCES app_user(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- бюджет и ledger (4.3)

CREATE TABLE budget_account (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES organization(id),
  scope_type      text NOT NULL CHECK (scope_type IN ('ORG','STUDY','CAMPAIGN')),
  scope_id        uuid NOT NULL,
  currency        char(3) NOT NULL,
  limit_amount    numeric(14,2) NOT NULL CHECK (limit_amount >= 0),
  reserved_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (reserved_amount >= 0),
  spent_amount    numeric(14,2) NOT NULL DEFAULT 0 CHECK (spent_amount >= 0),
  version         bigint NOT NULL DEFAULT 0,
  UNIQUE (org_id, scope_type, scope_id),
  -- страховка на уровне БД: даже если условный UPDATE в коде окажется ошибочным, перерасход невозможен
  CHECK (reserved_amount + spent_amount <= limit_amount)
);

CREATE TABLE budget_entry (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES organization(id),
  account_id       uuid NOT NULL REFERENCES budget_account(id),
  type             text NOT NULL CHECK (type IN ('RESERVE','RELEASE','CHARGE','REFUND','ADJUST')),
  amount           numeric(14,2) NOT NULL CHECK (amount > 0),
  currency         char(3) NOT NULL,
  ref_type         text,
  ref_id           uuid,
  idempotency_key  text NOT NULL UNIQUE,
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- бронирование (4.5)
-- Исправлено по ревью: сессия не хранит один moderator_id. Занятость модераторов вынесена
-- в session_moderator, на котором и стоит exclusion-ограничение.

CREATE TABLE session (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL REFERENCES organization(id),
  study_id   uuid NOT NULL REFERENCES study(id),
  starts_at  timestamptz NOT NULL,
  ends_at    timestamptz NOT NULL,
  status     text NOT NULL DEFAULT 'SCHEDULED'
               CHECK (status IN ('SCHEDULED','CONFIRMED','COMPLETED','NO_SHOW','CANCELLED','RESCHEDULED')),
  CHECK (ends_at > starts_at)
);

-- busy = [starts_at - buffer_before, ends_at + buffer_after) вычисляет приложение:
-- timestamptz + interval не IMMUTABLE, поэтому generated column здесь не подходит.
CREATE TABLE session_moderator (
  session_id    uuid NOT NULL REFERENCES session(id),
  org_id        uuid NOT NULL REFERENCES organization(id),
  moderator_id  uuid NOT NULL REFERENCES app_user(id),
  busy          tstzrange NOT NULL,
  active        boolean NOT NULL DEFAULT true,
  PRIMARY KEY (session_id, moderator_id),
  EXCLUDE USING gist (moderator_id WITH =, busy WITH &&) WHERE (active)
);

-- ---------------------------------------------------------------- outbox (раздел 1, 3.2)

CREATE TABLE outbox_event (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES organization(id),
  type             text NOT NULL,
  payload          jsonb NOT NULL,
  status           text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','DONE','FAILED')),
  attempts         int  NOT NULL DEFAULT 0,
  next_attempt_at  timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX outbox_pending_idx ON outbox_event (next_attempt_at) WHERE status = 'PENDING';

-- ---------------------------------------------------------------- аудит, append-only (4.9)

CREATE TABLE audit_event (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id        uuid NOT NULL REFERENCES organization(id),
  actor_id      uuid,
  entity        text NOT NULL,
  entity_id     text NOT NULL,
  action        text NOT NULL,
  before_state  jsonb,
  after_state   jsonb,
  request_id    text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION audit_forbid_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_event is append-only';
END
$$;

CREATE TRIGGER audit_event_append_only
  BEFORE UPDATE OR DELETE ON audit_event
  FOR EACH ROW EXECUTE FUNCTION audit_forbid_change();

-- ---------------------------------------------------------------- RLS (4.1)
-- FORCE нужен, чтобы RLS действовал и на владельца таблицы.
-- nullif(...) делает пустой контекст безопасным: без org_id строки не видны и не вставляются.

ALTER TABLE organization ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON organization
  USING (id = nullif(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (id = nullif(current_setting('app.org_id', true), '')::uuid);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'membership','study','budget_account','budget_entry',
    'outbox_event','audit_event','session','session_moderator'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($f$CREATE POLICY tenant_isolation ON %I
                     USING (org_id = nullif(current_setting('app.org_id', true), '')::uuid)
                     WITH CHECK (org_id = nullif(current_setting('app.org_id', true), '')::uuid)$f$, t);
  END LOOP;
END
$$;

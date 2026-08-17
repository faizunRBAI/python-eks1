-- 001_init.sql
--
-- Migrations run once each, in filename order, inside a transaction, and are
-- recorded in the schema_migrations table — so this file is never re-applied
-- after it succeeds. Never edit a migration that has already run anywhere: add a
-- new file with the next number instead.
--
-- Replace the example table with your own schema.

CREATE TABLE IF NOT EXISTS items (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS items_created_at_idx ON items (created_at DESC);

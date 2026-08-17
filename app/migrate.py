"""Database migration runner.

Applies every .sql file in db/migrations/ in filename order, each one exactly
once, each inside its own transaction, recording what ran in a
schema_migrations table. Invoked through bin/migrate by the db-migrate
Kubernetes Job during the configure stage, before the new Deployment is applied.

Three properties matter here, and each one is a failure this avoids:

  * **Run-once, not idempotent-by-convention.** Tracking applied files means a
    migration can be a plain ALTER TABLE. Re-running every file on every deploy
    only works while every author remembers IF NOT EXISTS, and stops working the
    first time somebody writes a data backfill.
  * **One transaction per file.** A migration that fails half way leaves nothing
    behind, so the next attempt starts from a known state.
  * **An advisory lock.** Two deploys racing would otherwise both try to apply
    the same file; the second waits instead.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import psycopg

MIGRATIONS_DIR = Path(__file__).resolve().parent.parent / "db" / "migrations"
# Any stable value works; it only has to be the same in every deploy.
LOCK_KEY = 8274461930572001


def main() -> int:
    dsn = (os.getenv("DATABASE_URL") or "").strip()
    if not dsn:
        print("DATABASE_URL is not set — no database in this configuration, nothing to migrate.")
        return 0
    if not MIGRATIONS_DIR.is_dir():
        print(f"No db/migrations directory at {MIGRATIONS_DIR} — nothing to migrate.")
        return 0

    files = sorted(p for p in MIGRATIONS_DIR.iterdir() if p.suffix == ".sql")
    print(f"Found {len(files)} migration file(s) in db/migrations.")
    if not files:
        return 0

    # autocommit so each file's BEGIN/COMMIT is explicit and the advisory lock
    # is not trapped inside an implicit transaction.
    with psycopg.connect(dsn, connect_timeout=10, autocommit=True) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                filename   TEXT PRIMARY KEY,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))

        applied = {row[0] for row in conn.execute("SELECT filename FROM schema_migrations")}

        ran = 0
        for path in files:
            if path.name in applied:
                print(f"skip   {path.name}")
                continue
            sql = path.read_text(encoding="utf-8")
            print(f"apply  {path.name}")
            conn.execute("BEGIN")
            try:
                conn.execute(sql)  # noqa: S608 — a migration file IS the statement
                conn.execute("INSERT INTO schema_migrations (filename) VALUES (%s)", (path.name,))
                conn.execute("COMMIT")
                ran += 1
            except Exception as exc:  # noqa: BLE001
                conn.execute("ROLLBACK")
                print(
                    f"Migration failed: {path.name} failed and was rolled back: {exc}",
                    file=sys.stderr,
                )
                return 1

        print("Schema already up to date." if ran == 0 else f"Applied {ran} migration(s).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — the exit code is the contract
        print(f"Migration failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc

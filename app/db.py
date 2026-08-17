"""Optional Postgres access.

The `database` module choice decides whether this blueprint provisions RDS. With
``database=none`` the deploy never creates the ``app-database`` secret, so
DATABASE_URL is absent and the service runs statelessly. Everything here is
written for both cases: ``is_configured()`` is the single question the rest of
the application asks.

TLS is handled by libpq rather than by code. PGSSLMODE and PGSSLROOTCERT are set
in the Kubernetes manifests, pointing at the Amazon RDS CA bundle baked into the
image, so the certificate is verified without a line of Python deciding whether
to trust it. RDS presents a certificate from a private CA that no system trust
store carries, and the alternative to shipping that bundle is an encrypted
channel nobody has authenticated.
"""

from __future__ import annotations

import os

from psycopg_pool import ConnectionPool

_DATABASE_URL = (os.getenv("DATABASE_URL") or "").strip()

_pool: ConnectionPool | None = None
if _DATABASE_URL:
    # open=False so importing this module never touches the network: /health
    # must answer while the database is unreachable, or a database outage turns
    # into a restart loop of otherwise healthy pods.
    _pool = ConnectionPool(
        conninfo=_DATABASE_URL,
        min_size=1,
        max_size=int(os.getenv("DB_POOL_MAX", "5")),
        timeout=5.0,
        open=False,
    )


def is_configured() -> bool:
    """Whether a database was configured for this deployment."""
    return _pool is not None


def open_pool() -> None:
    """Called from the application lifespan on startup."""
    if _pool is not None:
        _pool.open()


def close_pool() -> None:
    """Called from the application lifespan on shutdown."""
    if _pool is not None:
        _pool.close()


def ping() -> None:
    """Cheap round trip used by the readiness probe. Raises when unusable."""
    if _pool is None:
        return
    with _pool.connection(timeout=5.0) as conn:
        conn.execute("SELECT 1")

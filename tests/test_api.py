"""Endpoint contract the deploy pipeline depends on.

These run without a database on purpose: that is the `database=none` shape, and
it is also what CI has. The /ready-with-a-database path is exercised by the real
deploy, whose readiness probe is the same call.
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import app


def test_health_reports_ok_without_touching_the_database() -> None:
    with TestClient(app) as client:
        res = client.get("/health")
    assert res.status_code == 200
    body = res.json()
    assert body["status"] == "ok"
    assert isinstance(body["uptime_s"], int)


def test_ready_is_ready_when_no_database_is_configured() -> None:
    with TestClient(app) as client:
        res = client.get("/ready")
    assert res.status_code == 200
    assert res.json() == {"status": "ready", "database": "not configured"}


def test_info_describes_the_running_service() -> None:
    with TestClient(app) as client:
        res = client.get("/api/info")
    assert res.status_code == 200
    body = res.json()
    assert body["service"] == "udap-python-eks-api"
    assert body["database"] == "none"


def test_echo_returns_the_query_string() -> None:
    with TestClient(app) as client:
        res = client.get("/api/echo", params={"any": "value"})
    assert res.status_code == 200
    assert res.json() == {"received": {"any": "value"}}


def test_root_serves_the_operator_page() -> None:
    with TestClient(app) as client:
        res = client.get("/")
    assert res.status_code == 200
    assert res.headers["content-type"].startswith("text/html")


def test_unknown_routes_answer_404() -> None:
    with TestClient(app) as client:
        res = client.get("/does-not-exist")
    assert res.status_code == 404

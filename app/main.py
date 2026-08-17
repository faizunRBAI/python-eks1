"""FastAPI application.

The endpoints below are platform contract, not decoration: the deploy pipeline
health-checks ``/health`` through the load balancer and Kubernetes gates traffic
on ``/ready``. Replace everything under ``/api`` with your own routes; leave
those two, the static mount at ``/``, and the lifespan wiring alone.
"""

from __future__ import annotations

import json
import os
import sys
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from app import db

STARTED_AT = time.time()
STATIC_DIR = Path(__file__).resolve().parent.parent / "static"


def log(level: str, **fields: object) -> None:
    """One JSON object per line — what CloudWatch and `kubectl logs` both read."""
    stream = sys.stderr if level == "error" else sys.stdout
    print(json.dumps({"level": level, **fields}), file=stream, flush=True)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    db.open_pool()
    log("info", msg="listening", port=int(os.getenv("PORT", "8000")))
    try:
        yield
    finally:
        # Uvicorn stops accepting connections and drains in-flight requests on
        # SIGTERM before this runs, which is what makes the rolling update
        # actually zero-downtime.
        db.close_pool()
        log("info", msg="shutdown complete")


app = FastAPI(
    title="udap-python-eks-api",
    docs_url="/api/docs",
    openapi_url="/api/openapi.json",
    lifespan=lifespan,
)


@app.middleware("http")
async def access_log(request: Request, call_next):  # noqa: ANN001, ANN201
    began = time.perf_counter()
    response = await call_next(request)
    log(
        "info",
        method=request.method,
        path=request.url.path,
        status=response.status_code,
        duration_ms=round((time.perf_counter() - began) * 1000),
    )
    return response


@app.get("/health")
def health() -> dict[str, object]:
    """Liveness. Deliberately does NOT touch the database — a database outage
    must not make Kubernetes restart pods that are serving fine."""
    return {
        "status": "ok",
        "uptime_s": round(time.time() - STARTED_AT),
        "version": os.getenv("APP_VERSION", "dev"),
    }


@app.get("/ready")
def ready() -> JSONResponse:
    """Readiness. Checks the database, but only when one is configured, so the
    same manifest works with ``database=none``."""
    if not db.is_configured():
        return JSONResponse({"status": "ready", "database": "not configured"})
    try:
        db.ping()
    except Exception as exc:  # noqa: BLE001 — any failure means not ready
        # Logged as well as returned: when a rollout stalls, the pod log is what
        # the pipeline prints and what an operator reads. A reason that exists
        # only in an HTTP response body nobody called is a reason nobody sees.
        log("error", msg="readiness check failed", err=str(exc))
        return JSONResponse(
            {"status": "not ready", "database": "unreachable", "error": str(exc)},
            status_code=503,
        )
    return JSONResponse({"status": "ready", "database": "connected"})


@app.get("/api/info")
def info() -> dict[str, object]:
    return {
        "service": "udap-python-eks-api",
        "python": sys.version.split()[0],
        "environment": os.getenv("APP_ENV", "development"),
        "database": "configured" if db.is_configured() else "none",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(STARTED_AT)),
    }


@app.get("/api/echo")
def echo(request: Request) -> dict[str, object]:
    """Sample route to replace with your own."""
    return {"received": dict(request.query_params)}


# The operator UI, mounted last so every route above wins. Serves static/ at /
# because the platform's verify stage expects a real page there, not a JSON blob.
app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")

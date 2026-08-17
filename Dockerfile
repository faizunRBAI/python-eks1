# Major version and distro are pinned; the patch level floats so rebuilds pick
# up Debian security fixes instead of failing the image scan months later. Pin to
# a digest instead if byte-identical rebuilds matter more than staying patched.
FROM python:3.12-slim-bookworm AS deps

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# A virtualenv rather than the system site-packages: the runtime stage copies
# this one directory and nothing else, which is what keeps pip, setuptools and
# their vendored dependencies out of the final image.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt ./
RUN pip install -r requirements.txt

# The Amazon RDS certificate authority bundle. RDS presents a certificate from a
# private CA that is NOT in any system trust store, so without this bundle the
# only ways to connect are "no TLS" or "TLS without verification" — both of which
# send database credentials over a channel nobody has authenticated.
ADD https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
    /rds-global-bundle.pem
RUN head -1 /rds-global-bundle.pem | grep -q "BEGIN CERTIFICATE"

FROM python:3.12-slim-bookworm AS runtime

ENV APP_ENV=production \
    PORT=8000 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# Three things happen here, all driven by what the image scan actually finds on a
# stock Python image:
#
#  1. `apt-get upgrade` patches the OS packages the base image ships behind. Base
#     images trail their distribution's security archive by days, which is long
#     enough for openssl or zlib alone to fail the gate.
#  2. pip, setuptools and wheel are removed from the system interpreter. The
#     service runs uvicorn; it never installs a package at run time, and those
#     three carry most of the python-pkg findings on a stock image.
#  3. A non-root user, created before anything is copied so ownership is right
#     the first time rather than fixed up in a later layer.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip uninstall -y pip setuptools wheel 2>/dev/null || true \
    && rm -rf /usr/local/lib/python3.12/ensurepip \
    /usr/local/lib/python3.12/site-packages/pip* \
    /usr/local/lib/python3.12/site-packages/setuptools* \
    /usr/local/lib/python3.12/site-packages/wheel* \
    /usr/local/lib/python3.12/site-packages/pkg_resources \
    && groupadd -g 10001 app \
    && useradd -u 10001 -g app -M -s /usr/sbin/nologin app

COPY --from=deps --chown=app:app /opt/venv /opt/venv
COPY --from=deps --chown=app:app /rds-global-bundle.pem ./certs/rds-global-bundle.pem

# The whole application tree, with .dockerignore deciding what stays out. An
# allowlist of COPY lines silently drops every directory added later — a
# db/migrations/ that never reaches the image fails the migration Job with ENOENT
# and nothing readable in the log. An allowlist fails quietly; .dockerignore
# fails visibly.
COPY --chown=app:app . .

# pip is gone from the venv too: it did its job in the deps stage, and leaving it
# means the scanner reports pip's own advisories against a package the service
# never calls.
RUN rm -rf /opt/venv/lib/python3.12/site-packages/pip* \
    /opt/venv/lib/python3.12/site-packages/setuptools* \
    /opt/venv/lib/python3.12/site-packages/wheel* \
    /opt/venv/lib/python3.12/site-packages/pkg_resources \
    /opt/venv/bin/pip /opt/venv/bin/pip3 /opt/venv/bin/pip3.12

USER app

EXPOSE 8000

# urllib is in the standard library, so the check needs nothing extra installed.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request as u,sys; sys.exit(0 if u.urlopen('http://127.0.0.1:8000/health',timeout=3).status==200 else 1)"

# Exec form: uvicorn runs as PID 1 and receives SIGTERM directly, which is what
# lets the lifespan shutdown drain in-flight requests.
ENTRYPOINT ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
    "--no-server-header", "--proxy-headers", "--forwarded-allow-ips", "*"]

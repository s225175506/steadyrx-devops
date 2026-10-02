# syntax=docker/dockerfile:1
# Multi-stage build. The "test" stage carries the test and analysis tools and
# is used only by Jenkins. The "runtime" stage is the small, non-root image
# that is deployed to staging and production.

FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
# Patch OS packages so Trivy does not fail the gate on Debian CVEs (e.g. libpcre2).
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
# Upgrade pip first so the image does not ship a pip release with known CVEs.
RUN python -m pip install --upgrade pip
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM base AS test
COPY requirements-dev.txt .
RUN pip install -r requirements-dev.txt
COPY . .
CMD ["pytest", "tests/unit", "tests/integration"]

FROM base AS runtime
ARG APP_VERSION=dev
ARG BUILD_SHA=local
LABEL org.opencontainers.image.title="steadyrx-api" \
      org.opencontainers.image.description="SteadyRx medicine-related falls early warning API" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${BUILD_SHA}" \
      org.opencontainers.image.source="https://github.com/s225153983/steadyrx-devops"
ENV APP_VERSION=${APP_VERSION} \
    BUILD_SHA=${BUILD_SHA} \
    DATABASE_PATH=/data/steadyrx.db
# Production never installs packages at run time, so the package tooling is
# removed. This shrinks the attack surface and removes the vendored msgpack
# and the old setuptools that Trivy flagged as HIGH (see SECURITY.md).
RUN python -m pip uninstall -y pip setuptools wheel || true \
    && find /usr/local/lib -depth \( -name 'setuptools*' -o -name 'pip' -o -name 'pip-*' \
         -o -name 'msgpack*' -o -name 'ensurepip' -o -name 'wheel-*' \) -exec rm -rf {} + \
    && useradd --create-home --uid 10001 steadyrx \
    && mkdir -p /data && chown steadyrx:steadyrx /data
COPY app ./app
USER steadyrx
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health/ready', timeout=2)"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]

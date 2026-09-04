ARG PYTHON_IMAGE=python:3.11-slim@sha256:9534e5a8e315485d4061ed659af0fd78a284c015f9b73661b41d6bab25604534
FROM ${PYTHON_IMAGE}

ARG STATS_SOURCE_COMMIT=a0fed9e186fa85d16eefdaf62bd6dbecadb629af

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY app/ /app/

RUN pip install --no-cache-dir --require-hashes -r /app/requirements.txt \
    && groupadd --gid 1000 stats \
    && useradd --uid 1000 --gid 1000 --no-create-home --home-dir /nonexistent \
       --shell /usr/sbin/nologin stats \
    && chown -R 1000:1000 /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

LABEL org.opencontainers.image.source="https://github.com/mysalvium/p2pool-salvium" \
      org.opencontainers.image.revision="${STATS_SOURCE_COMMIT}"

USER 1000:1000
EXPOSE 8080

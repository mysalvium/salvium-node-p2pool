FROM python:3.11-slim

ARG STATS_SOURCE_COMMIT=a0fed9e186fa85d16eefdaf62bd6dbecadb629af

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY app/ /app/

RUN pip install --no-cache-dir -r /app/requirements.txt

LABEL org.opencontainers.image.source="https://github.com/trevorwilf/p2pool-salvium" \
      org.opencontainers.image.revision="${STATS_SOURCE_COMMIT}"

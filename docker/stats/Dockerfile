FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    git vim curl procps wget \
    && rm -rf /var/lib/apt/lists/*

ARG CACHEBUST=1
RUN git clone https://github.com/trevorwilf/p2pool-salvium.git /tmp/p2pool-repo
WORKDIR /tmp/p2pool-repo
RUN git fetch --all && git checkout updatestatistics

RUN mkdir /app
WORKDIR /app
RUN cp -r /tmp/p2pool-repo/docker-compose/statistics/app/* /app/

RUN pip install --no-cache-dir flask humanfriendly prefixed

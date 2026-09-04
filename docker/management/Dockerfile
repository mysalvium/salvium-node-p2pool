ARG ALPINE_IMAGE=alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
FROM ${ALPINE_IMAGE}

RUN apk add --no-cache \
    busybox-extras \
    ca-certificates \
    curl \
    jq

LABEL org.opencontainers.image.source="https://github.com/mysalvium/salvium-node-p2pool"

USER 65534:65534

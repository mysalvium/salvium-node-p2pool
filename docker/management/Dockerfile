ARG ALPINE_IMAGE=alpine:3.20
FROM ${ALPINE_IMAGE}

RUN apk add --no-cache \
    busybox-extras \
    ca-certificates \
    curl \
    jq

LABEL org.opencontainers.image.source="https://github.com/mysalvium/salvium-node-p2pool"

USER 65534:65534

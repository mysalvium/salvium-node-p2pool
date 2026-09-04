#!/usr/bin/env bash
set -euo pipefail

SALVIUMD_IMAGE="${SALVIUMD_IMAGE:-salviumd:local}"
P2POOL_IMAGE="${P2POOL_IMAGE:-p2pool-salvium:local}"

echo "Verifying the latest Salvium release without installing it..."
docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=512m \
  -e VERIFY_RELEASE_ONLY=1 \
  "$SALVIUMD_IMAGE"

echo "Verifying the latest P2Pool Salvium release without installing it..."
docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=256m \
  -e VERIFY_RELEASE_ONLY=1 \
  "$P2POOL_IMAGE"

echo "Both upstream releases passed verification. No binary was installed."

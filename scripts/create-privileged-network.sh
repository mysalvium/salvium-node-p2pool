#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

NETWORK_NAME="${SALVIUM_PRIVILEGED_RPC_NETWORK:-salvium_privileged_rpc}"
NETWORK_SUBNET="${SALVIUM_PRIVILEGED_RPC_SUBNET:-172.30.190.16/28}"

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  internal=$(docker network inspect "$NETWORK_NAME" --format '{{.Internal}}')
  configured_subnets=$(docker network inspect "$NETWORK_NAME" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')
  if [[ "$internal" != "true" || " $configured_subnets " != *" $NETWORK_SUBNET "* ]]; then
    echo "ERROR: existing network $NETWORK_NAME is not internal with subnet $NETWORK_SUBNET." >&2
    exit 1
  fi
  echo "Using existing internal network $NETWORK_NAME ($NETWORK_SUBNET)."
  exit 0
fi

docker network create \
  --driver bridge \
  --internal \
  --subnet "$NETWORK_SUBNET" \
  --label com.mysalvium.purpose=privileged-rpc \
  "$NETWORK_NAME" >/dev/null

echo "Created internal network $NETWORK_NAME ($NETWORK_SUBNET)."

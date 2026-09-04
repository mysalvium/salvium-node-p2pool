#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env.example}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"

command -v docker >/dev/null
command -v jq >/dev/null

config=$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --format json)

check() {
  description="$1"
  expression="$2"
  if ! printf '%s' "$config" | jq -e "$expression" >/dev/null; then
    echo "FAIL: $description" >&2
    exit 1
  fi
  echo "PASS: $description"
}

check "unrestricted RPC is not host-published" \
  '(.services.salviumd.ports // []) | all(.target != 19081)'
check "restricted RPC has an explicit host address" \
  '(.services.salviumd.ports // []) | any(.target == 19089 and (.host_ip | length > 0))'
check "Stratum has an explicit non-public host address" \
  '(.services.p2pool.ports // []) | any(.target == 3333 and (.host_ip | length > 0) and .host_ip != "0.0.0.0")'
check "privileged RPC network is externally managed" \
  '.networks.privileged_rpc.external == true'
check "only salviumd joins the privileged network in this stack" \
  '([.services | to_entries[] | select(.value.networks | has("privileged_rpc")) | .key] | sort) == ["salviumd"]'
check "stats is isolated from the node network" \
  '(.services.stats.networks | has("node")) == false'
check "management services are isolated from the node network" \
  '[.services["salviumd-updater"], .services["p2pool-updater"], .services["p2pool-watchdog"]] | all((.networks | has("node")) == false)'
check "firewall has NET_ADMIN but no Docker socket mount" \
  '(.services.firewall.cap_add | index("NET_ADMIN") != null) and ((.services.firewall.volumes // []) | length == 0)'

stats_commit=$(sed -n 's/^STATS_SOURCE_COMMIT=//p' "$ENV_FILE")
if ! printf '%s' "$stats_commit" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "FAIL: stats source is pinned to a full commit" >&2
  exit 1
fi
grep -Fq "ARG STATS_SOURCE_COMMIT=$stats_commit" docker/stats/Dockerfile
echo "PASS: stats source is pinned to a full commit"

grep -Fq -- '--ctdir ORIGINAL --ctorigdst "$LAN_BIND_IP" --ctorigdstport' docker/firewall/salvium-firewall.sh
echo "PASS: firewall filtering applies only to original inbound host-port traffic"

grep -Fq 'ipt -C INPUT -j "$HOST_CHAIN"' docker/firewall/salvium-firewall.sh
echo "PASS: firewall also covers same-host Docker bridge traffic"

echo "All Compose hardening checks passed."

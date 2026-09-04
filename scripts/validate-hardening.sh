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
check "no container mounts the Docker socket" \
  '[.services | to_entries[].value | (.volumes // [])[]?] | all(.source != "/var/run/docker.sock")'
check "management services run non-root with read-only filesystems" \
  '[.services["salviumd-updater"], .services["p2pool-updater"], .services["p2pool-watchdog"]] | all((.user | length > 0) and .user != "0" and .user != "0:0" and .read_only == true)'
check "management services drop capabilities and prevent privilege escalation" \
  '[.services["salviumd-updater"], .services["p2pool-updater"], .services["p2pool-watchdog"]] | all((.cap_drop | index("ALL") != null) and ([.security_opt[] | startswith("no-new-privileges")] | any))'
check "each management service has only its dedicated broker request directory" \
  '(.services["salviumd-updater"].volumes | any(.target == "/broker" and ((.read_only // false) == false))) and
   (.services["p2pool-updater"].volumes | any(.target == "/broker" and ((.read_only // false) == false))) and
   (.services["p2pool-watchdog"].volumes | any(.target == "/broker" and ((.read_only // false) == false)))'
check "P2Pool is read-only without SYS_ADMIN" \
  '.services.p2pool.read_only == true and
   (.services.p2pool.cap_drop | index("ALL") != null) and
   (.services.p2pool.cap_add | index("IPC_LOCK") != null) and
   (.services.p2pool.cap_add | index("SYS_ADMIN") == null) and
   ([.services.p2pool.security_opt[] | startswith("no-new-privileges")] | any)'
check "statistics runs non-root and read-only without capabilities" \
  '.services.stats.user != "0" and .services.stats.user != "0:0" and
   .services.stats.read_only == true and
   (.services.stats.cap_drop | index("ALL") != null) and
   ([.services.stats.security_opt[] | startswith("no-new-privileges")] | any)'
check "statistics uses the unprivileged internal HTTP port" \
  '(.services.stats.ports | any(.target == 8080)) and
   (.services.stats.healthcheck.test | join(" ") | contains("127.0.0.1:8080")) and
   (.services.stats.command[0] == "gunicorn")'
check "all long-running services have process limits" \
  '[.services.salviumd, .services.p2pool, .services["salviumd-updater"],
    .services["p2pool-updater"], .services["p2pool-watchdog"],
    .services.stats, .services.firewall] | all(.pids_limit > 0)'
check "watchdog receives broker status read-only" \
  '.services["p2pool-watchdog"].volumes | any(.target == "/docker-status" and .read_only == true)'
check "root broker source is not mounted into any container" \
  '[.services | to_entries[].value | (.volumes // [])[]?] | all(.target != "/ops" and (.source | endswith("/salvium-docker-broker.sh") | not))'
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

grep -Fq 'process_target salviumd 120 salviumd-updater' ops/salvium-docker-broker.sh
grep -Fq 'process_target salvium-p2pool 60 p2pool-updater p2pool-watchdog' ops/salvium-docker-broker.sh
if grep -Eq 'eval|sh -c|bash -c' ops/salvium-docker-broker.sh; then
  echo "FAIL: host broker must not evaluate caller-controlled commands" >&2
  exit 1
fi
echo "PASS: host broker uses fixed targets and has no command evaluator"

echo "All Compose hardening checks passed."

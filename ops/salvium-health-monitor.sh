#!/usr/bin/env bash
# Root-owned installed health monitor for the live Salvium stack.
set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

die() {
    printf 'salvium-health-monitor: %s\n' "$*" >&2
    exit 1
}

SELF_PATH=$(readlink -f -- "$0")
HOST_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)
OPERATIONS_ROOT=$(dirname -- "$HOST_DIR")
STATUS_DIR="$OPERATIONS_ROOT/status"
CONFIG_FILE="$HOST_DIR/operations.conf"
LOG_FILE="$HOST_DIR/health.log"
STATE_FILE="$STATUS_DIR/health.state"

secure_root_file() {
    local path=$1 uid mode
    [[ -f "$path" && ! -L "$path" ]] || die "unsafe or missing file: $path"
    uid=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    [[ "$uid" = 0 ]] || die "$path must be owned by root"
    (( (8#$mode & 022) == 0 )) || die "$path must not be group/other writable"
}

secure_root_directory() {
    local path=$1 uid mode
    [[ -d "$path" && ! -L "$path" ]] || die "unsafe or missing directory: $path"
    uid=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    [[ "$uid" = 0 ]] || die "$path must be owned by root"
    (( (8#$mode & 022) == 0 )) || die "$path must not be group/other writable"
}

secure_root_file "$SELF_PATH"
secure_root_directory "$HOST_DIR"
secure_root_directory "$STATUS_DIR"
secure_root_file "$CONFIG_FILE"

config_value() {
    local key=$1
    sed -n "s/^${key}=//p" "$CONFIG_FILE" | tail -n 1
}

DATA_ROOT=$(config_value DATA_ROOT)
APP_ROOT=$(config_value APP_ROOT)
BACKUP_DIR=$(config_value BACKUP_DIR)
LAN_BIND_IP=$(config_value LAN_BIND_IP)
RPC_PORT=$(config_value RPC_PORT)
STATS_PORT=$(config_value STATS_PORT)
PORTAINER_COMPOSE=$(config_value PORTAINER_COMPOSE)
MAX_BACKUP_AGE=$(config_value MAX_BACKUP_AGE)
EXPECTED_SALVIUMD_IMAGE=$(config_value EXPECTED_SALVIUMD_IMAGE)
EXPECTED_P2POOL_IMAGE=$(config_value EXPECTED_P2POOL_IMAGE)
EXPECTED_STATS_IMAGE=$(config_value EXPECTED_STATS_IMAGE)
EXPECTED_FIREWALL_IMAGE=$(config_value EXPECTED_FIREWALL_IMAGE)
EXPECTED_MANAGEMENT_IMAGE=$(config_value EXPECTED_MANAGEMENT_IMAGE)

for path in "$DATA_ROOT" "$APP_ROOT" "$BACKUP_DIR"; do
    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid configured path"
done
[[ "$LAN_BIND_IP" =~ ^[0-9a-fA-F:.]+$ ]] || die "invalid LAN_BIND_IP"
[[ "$RPC_PORT" =~ ^[0-9]+$ && "$STATS_PORT" =~ ^[0-9]+$ ]] || die "invalid port"
[[ "$MAX_BACKUP_AGE" =~ ^[0-9]+$ ]] || die "invalid MAX_BACKUP_AGE"

declare -a failures=()
fail() { failures+=("$1"); }

container_state() {
    local name=$1 expected_image=$2 health_required=$3 state image health
    state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
    image=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || true)
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)
    [[ "$state" = running ]] || fail "$name is not running"
    [[ "$image" = "$expected_image" ]] || fail "$name image differs from the installed operations configuration"
    if [[ "$health_required" = yes && "$health" != healthy ]]; then
        fail "$name health is ${health:-unknown}"
    fi
}

container_state salviumd "$EXPECTED_SALVIUMD_IMAGE" yes
container_state salvium-p2pool "$EXPECTED_P2POOL_IMAGE" no
container_state salvium-stats "$EXPECTED_STATS_IMAGE" yes
container_state salvium-firewall "$EXPECTED_FIREWALL_IMAGE" yes
container_state salviumd-updater "$EXPECTED_MANAGEMENT_IMAGE" no
container_state p2pool-updater "$EXPECTED_MANAGEMENT_IMAGE" no
container_state p2pool-watchdog "$EXPECTED_MANAGEMENT_IMAGE" no

p2pool_security=$(docker inspect salvium-p2pool --format '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{json .HostConfig.CapAdd}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.SecurityOpt}}' 2>/dev/null || true)
[[ "$p2pool_security" == *'|true|'* && "$p2pool_security" == *'CAP_IPC_LOCK'* && "$p2pool_security" != *'CAP_SYS_ADMIN'* && "$p2pool_security" == *'"ALL"'* && "$p2pool_security" == *'no-new-privileges'* ]] \
    || fail "P2Pool privilege boundary does not match policy"

stats_security=$(docker inspect salvium-stats --format '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.SecurityOpt}}' 2>/dev/null || true)
[[ "$stats_security" == 1000:1000'|true|'* && "$stats_security" == *'"ALL"'* && "$stats_security" == *'no-new-privileges'* ]] \
    || fail "statistics privilege boundary does not match policy"

if ! curl -fsS --max-time 8 "http://${LAN_BIND_IP}:${RPC_PORT}/get_info" | jq -e '.synchronized == true' >/dev/null 2>&1; then
    fail "restricted node RPC is unavailable or unsynchronized"
fi
if ! curl -fsS --max-time 8 "http://${LAN_BIND_IP}:${STATS_PORT}/" >/dev/null 2>&1; then
    fail "statistics dashboard is unavailable"
fi
if ! docker exec salvium-firewall /usr/local/sbin/salvium-firewall check >/dev/null 2>&1; then
    fail "Salvium firewall rules failed validation"
fi

now=$(date +%s)
for stats_file in "$DATA_ROOT/p2pool-stats/local/p2p" "$DATA_ROOT/p2pool-stats/local/stratum"; do
    if [[ ! -f "$stats_file" ]]; then
        fail "P2Pool statistics file is missing: ${stats_file##*/}"
        continue
    fi
    mtime=$(stat -c %Y -- "$stats_file" 2>/dev/null || printf 0)
    (( now - mtime <= 600 )) || fail "P2Pool statistics are stale: ${stats_file##*/}"
done

broker_state="$DATA_ROOT/docker-control/status/p2pool.state"
if [[ -r "$broker_state" ]]; then
    read -r _broker_status _broker_restarts broker_updated _broker_extra < "$broker_state" || true
    [[ "${broker_updated:-}" =~ ^[0-9]+$ && $((now - broker_updated)) -le 180 ]] \
        || fail "Docker broker status is stale"
else
    fail "Docker broker status is missing"
fi

latest_backup=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'salvium-full-*.tar.zst' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)
if [[ -z "$latest_backup" ]]; then
    fail "no Salvium backup archive exists"
else
    backup_mtime=$(stat -c %Y -- "$latest_backup")
    (( now - backup_mtime <= MAX_BACKUP_AGE )) || fail "latest Salvium backup is too old"
    [[ -f "${latest_backup}.sha256" ]] || fail "latest Salvium backup checksum is missing"
fi

if [[ -n "$PORTAINER_COMPOSE" ]]; then
    [[ -f "$PORTAINER_COMPOSE" ]] || fail "Portainer Compose file is missing"
    if [[ -f "$PORTAINER_COMPOSE" ]] && ! cmp -s -- "$APP_ROOT/compose.yaml" "$PORTAINER_COMPOSE"; then
        fail "repository and Portainer Compose files differ"
    fi
fi

previous=unknown
[[ -r "$STATE_FILE" ]] && read -r previous _ < "$STATE_FILE" || true
status=ok
(( ${#failures[@]} == 0 )) || status=failed
tmp=$(mktemp "$HOST_DIR/.health-state.XXXXXX")
printf '%s %s\n' "$status" "$now" > "$tmp"
chmod 0644 "$tmp"
mv -fT -- "$tmp" "$STATE_FILE"

if [[ "$status" = failed ]]; then
    message=$(IFS='; '; printf '%s' "${failures[*]}")
    printf '%s FAILED %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >> "$LOG_FILE"
    printf 'Salvium health check failed: %s\n' "$message" >&2
    exit 1
fi

if [[ "$previous" != ok ]]; then
    printf '%s OK all monitored boundaries recovered\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG_FILE"
fi

if [[ "${1:-run}" = check ]]; then
    printf 'PASS: live Salvium health, hardening, backup age, firewall, and Compose synchronization\n'
fi

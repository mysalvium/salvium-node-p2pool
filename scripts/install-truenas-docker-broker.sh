#!/usr/bin/env bash
# Install the root-owned allowlisted Docker broker and its TrueNAS Cron Job.
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
ENV_FILE=${2:-$REPO_DIR/.env}
ACTION=${1:-install}
CRON_DESCRIPTION="Salvium restricted Docker controller"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

read_env_value() {
    local key=$1 default=$2 value
    value=$(sed -n "s/^${key}=//p" "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d '\r')
    printf '%s' "${value:-$default}"
}

[[ $(id -u) -eq 0 ]] || die "run this installer as root"
[[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"
command -v docker >/dev/null || die "docker is required"
command -v jq >/dev/null || die "jq is required"
command -v midclt >/dev/null || die "this installer requires TrueNAS midclt"

DATA_ROOT=$(read_env_value SALVIUM_DATA_ROOT "")
PUID=$(read_env_value PUID 1000)
PGID=$(read_env_value PGID 1000)
[[ "$DATA_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "SALVIUM_DATA_ROOT must be a simple absolute path without spaces"
[[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]] || die "PUID and PGID must be numeric"

CONTROL_ROOT="$DATA_ROOT/docker-control"
HOST_DIR="$CONTROL_ROOT/host"
REQUEST_ROOT="$CONTROL_ROOT/requests"
STATUS_DIR="$CONTROL_ROOT/status"
SOURCE_BROKER="$REPO_DIR/ops/salvium-docker-broker.sh"
INSTALLED_BROKER="$HOST_DIR/salvium-docker-broker.sh"
CONFIG_FILE="$HOST_DIR/broker.conf"

check_cron() {
    local matches
    matches=$(midclt call cronjob.query | jq -c --arg description "$CRON_DESCRIPTION" \
        '[.[] | select(.description == $description)]')
    [[ $(jq 'length' <<< "$matches") -eq 1 ]] || die "expected exactly one TrueNAS broker Cron Job"
    jq -e --arg command "/usr/bin/bash $INSTALLED_BROKER run" \
        '.[0] | .enabled == true and .user == "root" and .command == $command and
         .schedule == {minute: "*", hour: "*", dom: "*", month: "*", dow: "*"}' \
        <<< "$matches" >/dev/null || die "TrueNAS broker Cron Job does not match the secure configuration"
}

check_containers() {
    local container socket_count user readonly security caps
    for container in salviumd-updater p2pool-updater p2pool-watchdog; do
        docker inspect "$container" >/dev/null 2>&1 || die "container is missing: $container"
        socket_count=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}1{{end}}{{end}}' "$container")
        [[ -z "$socket_count" ]] || die "$container still mounts the Docker socket"
        user=$(docker inspect --format '{{.Config.User}}' "$container")
        readonly=$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$container")
        security=$(docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$container")
        caps=$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$container")
        [[ -n "$user" && "$user" != 0 && "$user" != 0:0 ]] || die "$container still runs as root"
        [[ "$readonly" = true ]] || die "$container root filesystem is writable"
        [[ "$security" == *no-new-privileges* ]] || die "$container lacks no-new-privileges"
        [[ "$caps" == *ALL* ]] || die "$container does not drop all capabilities"
        if docker exec "$container" /bin/sh -c 'command -v docker' >/dev/null 2>&1; then
            die "$container unexpectedly contains the Docker CLI"
        fi
    done
}

if [[ "$ACTION" = check ]]; then
    [[ -x "$INSTALLED_BROKER" ]] || die "broker is not installed"
    /usr/bin/bash "$INSTALLED_BROKER" check
    check_cron
    check_containers
    printf 'PASS: TrueNAS Cron Job and all three management containers are hardened\n'
    exit 0
fi
[[ "$ACTION" = install ]] || die "usage: $0 [install|check] [path-to-.env]"
[[ -f "$SOURCE_BROKER" ]] || die "broker source is missing: $SOURCE_BROKER"

install -d -m 0755 -o root -g root "$CONTROL_ROOT" "$REQUEST_ROOT" "$STATUS_DIR"
install -d -m 0700 -o root -g root "$HOST_DIR"
for requester in salviumd-updater p2pool-updater p2pool-watchdog; do
    install -d -m 0770 -o "$PUID" -g "$PGID" "$REQUEST_ROOT/$requester"
done

install -m 0700 -o root -g root "$SOURCE_BROKER" "$HOST_DIR/.broker.new"
mv -fT -- "$HOST_DIR/.broker.new" "$INSTALLED_BROKER"

CONFIG_TMP="$HOST_DIR/.broker.conf.$$"
printf 'REQUEST_UID=%s\nMIN_RESTART_INTERVAL=300\nDOCKER_BIN=/usr/bin/docker\nTIMEOUT_BIN=/usr/bin/timeout\nLOGGER_BIN=/usr/bin/logger\n' \
    "$PUID" > "$CONFIG_TMP"
chmod 0600 "$CONFIG_TMP"
chown root:root "$CONFIG_TMP"
mv -fT -- "$CONFIG_TMP" "$CONFIG_FILE"

/usr/bin/bash "$INSTALLED_BROKER" status-only

CRON_COMMAND="/usr/bin/bash $INSTALLED_BROKER run"
CRON_PAYLOAD=$(jq -cn --arg command "$CRON_COMMAND" --arg description "$CRON_DESCRIPTION" '{
    user: "root",
    command: $command,
    description: $description,
    enabled: true,
    stdout: true,
    stderr: false,
    schedule: {minute: "*", hour: "*", dom: "*", month: "*", dow: "*"}
}')
mapfile -t CRON_IDS < <(midclt call cronjob.query | jq -r --arg description "$CRON_DESCRIPTION" \
    '.[] | select(.description == $description) | .id')
if (( ${#CRON_IDS[@]} > 1 )); then
    die "multiple TrueNAS broker Cron Jobs exist; remove duplicates manually"
elif (( ${#CRON_IDS[@]} == 1 )); then
    midclt call cronjob.update "${CRON_IDS[0]}" "$CRON_PAYLOAD" >/dev/null
    printf 'Updated TrueNAS Cron Job %s.\n' "${CRON_IDS[0]}"
else
    CRON_ID=$(midclt call cronjob.create "$CRON_PAYLOAD" | jq -r '.id')
    printf 'Created TrueNAS Cron Job %s.\n' "$CRON_ID"
fi

/usr/bin/bash "$INSTALLED_BROKER" run
check_cron
printf 'Installed restricted Docker broker at %s\n' "$INSTALLED_BROKER"
printf 'The broker is scheduled every minute and no container can access its files.\n'

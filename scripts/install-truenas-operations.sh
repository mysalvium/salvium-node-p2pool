#!/usr/bin/env bash
# Install root-owned backup, restore-test, and health-monitor scripts plus
# their idempotent TrueNAS Cron Jobs.
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
ACTION=${1:-install}
ENV_FILE=${2:-$REPO_DIR/.env}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
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
APP_ROOT=$(read_env_value SALVIUM_APP_ROOT "")
BACKUP_DIR=$(read_env_value SALVIUM_BACKUP_DIR /mnt/sharedrive/backups/salvium-node)
LAN_BIND_IP=$(read_env_value LAN_BIND_IP 192.168.1.54)
RPC_PORT=$(read_env_value SALVIUM_RESTRICTED_RPC_PORT 19089)
STATS_PORT=$(read_env_value STATS_PORT 3000)
PORTAINER_COMPOSE=$(read_env_value PORTAINER_STACK_COMPOSE "")
[[ -n "$PORTAINER_COMPOSE" ]] || PORTAINER_COMPOSE="$(dirname -- "$ENV_FILE")/docker-compose.yml"
SOURCE_MOUNT_ROOT=$(dirname -- "$APP_ROOT")
SOURCE_NAME=$(basename -- "$APP_ROOT")
SOURCE_DATASET=$(findmnt -n -o SOURCE -T "$APP_ROOT")

for path in "$DATA_ROOT" "$APP_ROOT" "$BACKUP_DIR" "$PORTAINER_COMPOSE"; do
    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "configured paths must be simple absolute paths without spaces"
done

OPERATIONS_ROOT="$DATA_ROOT/operations"
HOST_DIR="$OPERATIONS_ROOT/host"
STATUS_DIR="$OPERATIONS_ROOT/status"
CONFIG_FILE="$HOST_DIR/operations.conf"

cron_payload() {
    local command=$1 description=$2 minute=$3 hour=$4 dow=$5 hide_stdout=$6
    jq -cn --arg command "$command" --arg description "$description" \
        --arg minute "$minute" --arg hour "$hour" --arg dow "$dow" \
        --argjson stdout "$hide_stdout" '{
          user: "root", command: $command, description: $description,
          enabled: true, stdout: $stdout, stderr: false,
          schedule: {minute: $minute, hour: $hour, dom: "*", month: "*", dow: $dow}
        }'
}

upsert_cron() {
    local description=$1 payload=$2
    mapfile -t ids < <(midclt call cronjob.query | jq -r --arg description "$description" '.[] | select(.description == $description) | .id')
    (( ${#ids[@]} <= 1 )) || die "multiple TrueNAS Cron Jobs exist for: $description"
    if (( ${#ids[@]} == 1 )); then
        midclt call cronjob.update "${ids[0]}" "$payload" >/dev/null
        printf 'Updated TrueNAS Cron Job %s (%s).\n' "${ids[0]}" "$description"
    else
        id=$(midclt call cronjob.create "$payload" | jq -r '.id')
        printf 'Created TrueNAS Cron Job %s (%s).\n' "$id" "$description"
    fi
}

check_cron() {
    local description=$1 command=$2 matches
    matches=$(midclt call cronjob.query | jq -c --arg description "$description" '[.[] | select(.description == $description)]')
    [[ $(jq 'length' <<< "$matches") -eq 1 ]] || die "expected one Cron Job: $description"
    jq -e --arg command "$command" '.[0] | .enabled == true and .user == "root" and .command == $command' <<< "$matches" >/dev/null \
        || die "Cron Job does not match: $description"
}

if [[ "$ACTION" = verify-backup ]]; then
    /usr/bin/bash "$HOST_DIR/verify-salvium-backup.sh"
    exit 0
fi

if [[ "$ACTION" = check ]]; then
    [[ -x "$HOST_DIR/salvium-health-monitor.sh" ]] || die "health monitor is not installed"
    [[ -x "$HOST_DIR/backup-salvium.sh" ]] || die "backup script is not installed"
    [[ -x "$HOST_DIR/verify-salvium-backup.sh" ]] || die "backup verifier is not installed"
    check_cron "Salvium live health monitor" "/usr/bin/bash $HOST_DIR/salvium-health-monitor.sh run"
    check_cron "Salvium weekly compressed backup" "/usr/bin/bash $HOST_DIR/backup-salvium.sh"
    check_cron "Salvium weekly restore verification" "/usr/bin/bash $HOST_DIR/verify-salvium-backup.sh"
    /usr/bin/bash "$HOST_DIR/salvium-health-monitor.sh" check
    printf 'PASS: root-owned operations scripts and TrueNAS Cron Jobs are installed\n'
    exit 0
fi
[[ "$ACTION" = install ]] || die "usage: $0 [install|check|verify-backup] [path-to-.env]"

install -d -m 0700 -o root -g root "$OPERATIONS_ROOT" "$HOST_DIR" "$STATUS_DIR"
for script in backup-salvium.sh salvium-health-monitor.sh verify-salvium-backup.sh; do
    install -m 0700 -o root -g root "$REPO_DIR/ops/$script" "$HOST_DIR/.$script.new"
    mv -fT -- "$HOST_DIR/.$script.new" "$HOST_DIR/$script"
done

config_tmp="$HOST_DIR/.operations.conf.$$"
{
    printf 'DATA_ROOT=%s\n' "$DATA_ROOT"
    printf 'APP_ROOT=%s\n' "$APP_ROOT"
    printf 'BACKUP_DIR=%s\n' "$BACKUP_DIR"
    printf 'SOURCE_DATASET=%s\n' "$SOURCE_DATASET"
    printf 'SOURCE_MOUNT_ROOT=%s\n' "$SOURCE_MOUNT_ROOT"
    printf 'SOURCE_NAME=%s\n' "$SOURCE_NAME"
    printf 'LAN_BIND_IP=%s\n' "$LAN_BIND_IP"
    printf 'RPC_PORT=%s\n' "$RPC_PORT"
    printf 'STATS_PORT=%s\n' "$STATS_PORT"
    printf 'PORTAINER_COMPOSE=%s\n' "$PORTAINER_COMPOSE"
    printf 'MAX_BACKUP_AGE=777600\n'
    printf 'EXPECTED_SALVIUMD_IMAGE=%s\n' "$(read_env_value SALVIUMD_IMAGE salviumd:local)"
    printf 'EXPECTED_P2POOL_IMAGE=%s\n' "$(read_env_value P2POOL_IMAGE p2pool-salvium:local)"
    printf 'EXPECTED_STATS_IMAGE=%s\n' "$(read_env_value STATS_IMAGE salvium-stats:local)"
    printf 'EXPECTED_FIREWALL_IMAGE=%s\n' "$(read_env_value FIREWALL_IMAGE salvium-firewall:local)"
    printf 'EXPECTED_MANAGEMENT_IMAGE=%s\n' "$(read_env_value MANAGEMENT_IMAGE salvium-management:local)"
} > "$config_tmp"
chmod 0600 "$config_tmp"
chown root:root "$config_tmp"
mv -fT -- "$config_tmp" "$CONFIG_FILE"

health_command="/usr/bin/bash $HOST_DIR/salvium-health-monitor.sh run"
backup_command="/usr/bin/bash $HOST_DIR/backup-salvium.sh"
verify_command="/usr/bin/bash $HOST_DIR/verify-salvium-backup.sh"
upsert_cron "Salvium live health monitor" "$(cron_payload "$health_command" "Salvium live health monitor" '*/5' '*' '*' true)"
upsert_cron "Salvium weekly compressed backup" "$(cron_payload "$backup_command" "Salvium weekly compressed backup" 15 3 0 false)"
upsert_cron "Salvium weekly restore verification" "$(cron_payload "$verify_command" "Salvium weekly restore verification" 0 5 0 true)"

/usr/bin/bash "$HOST_DIR/salvium-health-monitor.sh" check
printf 'Installed root-owned health, backup, and restore-verification operations.\n'

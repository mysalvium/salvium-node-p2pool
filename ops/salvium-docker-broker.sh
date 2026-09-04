#!/usr/bin/env bash
# Root-owned, host-side Docker control broker.
#
# This file is a source template. install-truenas-docker-broker.sh copies it to
# a root-only directory outside the repository before TrueNAS schedules it.
# Containers never mount this script, its configuration, or the Docker socket.
set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

die() {
    printf 'salvium-docker-broker: %s\n' "$*" >&2
    exit 1
}

SELF_PATH=$(readlink -f -- "$0")
HOST_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)
CONTROL_ROOT=$(dirname -- "$HOST_DIR")
REQUEST_ROOT="$CONTROL_ROOT/requests"
STATUS_DIR="$CONTROL_ROOT/status"
CONFIG_FILE="$HOST_DIR/broker.conf"
LOG_FILE="$HOST_DIR/broker.log"

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
secure_root_file "$CONFIG_FILE"

config_value() {
    local key=$1
    sed -n "s/^${key}=//p" "$CONFIG_FILE" | tail -n 1
}

REQUEST_UID=$(config_value REQUEST_UID)
MIN_RESTART_INTERVAL=$(config_value MIN_RESTART_INTERVAL)
DOCKER_BIN=$(config_value DOCKER_BIN)
TIMEOUT_BIN=$(config_value TIMEOUT_BIN)
LOGGER_BIN=$(config_value LOGGER_BIN)

[[ "$REQUEST_UID" =~ ^[0-9]+$ ]] || die "REQUEST_UID must be numeric"
[[ "$MIN_RESTART_INTERVAL" =~ ^[0-9]+$ ]] || die "MIN_RESTART_INTERVAL must be numeric"
[[ "$DOCKER_BIN" =~ ^/[A-Za-z0-9._/-]+$ && -x "$DOCKER_BIN" ]] || die "invalid DOCKER_BIN"
[[ "$TIMEOUT_BIN" =~ ^/[A-Za-z0-9._/-]+$ && -x "$TIMEOUT_BIN" ]] || die "invalid TIMEOUT_BIN"
[[ "$LOGGER_BIN" =~ ^/[A-Za-z0-9._/-]+$ && -x "$LOGGER_BIN" ]] || die "invalid LOGGER_BIN"

rotate_log() {
    local size=0 tmp
    [[ -f "$LOG_FILE" ]] && size=$(stat -c %s -- "$LOG_FILE" 2>/dev/null || printf 0)
    if (( size > 1048576 )); then
        tmp="$HOST_DIR/.broker.log.$$"
        tail -n 1000 "$LOG_FILE" > "$tmp"
        chmod 0600 "$tmp"
        mv -fT -- "$tmp" "$LOG_FILE"
    fi
}

log_message() {
    local message=$*
    rotate_log
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >> "$LOG_FILE"
    "$LOGGER_BIN" -t salvium-docker-broker -- "$message" 2>/dev/null || true
}

for required_dir in "$REQUEST_ROOT/salviumd-updater" "$REQUEST_ROOT/p2pool-updater" \
                    "$REQUEST_ROOT/p2pool-watchdog" "$STATUS_DIR"; do
    [[ -d "$required_dir" && ! -L "$required_dir" ]] || die "missing broker directory: $required_dir"
done
secure_root_directory "$STATUS_DIR"

exec 9>"$HOST_DIR/broker.lock"
flock -n 9 || exit 0

write_p2pool_status() {
    local output status restarts updated tmp
    output=$("$DOCKER_BIN" inspect --format '{{.State.Status}} {{.RestartCount}}' salvium-p2pool 2>/dev/null || true)
    read -r status restarts _ <<< "$output"
    case "$status" in
        created|restarting|running|removing|paused|exited|dead) ;;
        *) status=unknown ;;
    esac
    [[ "${restarts:-}" =~ ^[0-9]+$ ]] || restarts=-1
    updated=$(date +%s)
    tmp="$HOST_DIR/.p2pool.state.$$"
    printf '%s %s %s\n' "$status" "$restarts" "$updated" > "$tmp"
    chmod 0644 "$tmp"
    mv -fT -- "$tmp" "$STATUS_DIR/p2pool.state"
}

write_result() {
    local requester=$1 request_id=$2 result=$3 target=$4 tmp destination
    destination="$REQUEST_ROOT/$requester/restart.result"
    tmp=$(mktemp "$HOST_DIR/.result.XXXXXX")
    printf '%s %s %s %s\n' "$request_id" "$result" "$target" "$(date +%s)" > "$tmp"
    chmod 0644 "$tmp"
    mv -fT -- "$tmp" "$destination"
}

CLAIM_REQUESTER=
CLAIM_ID=
CLAIM_FILE=
claim_request() {
    local requester=$1 request claim owner size links request_id
    request="$REQUEST_ROOT/$requester/restart.request"
    claim="$HOST_DIR/claimed.$requester"

    if [[ ! -e "$claim" ]]; then
        [[ -e "$request" || -L "$request" ]] || return 1
        if [[ -L "$request" || ! -f "$request" ]]; then
            rm -f -- "$request"
            log_message "rejected non-regular request from $requester"
            return 1
        fi
        read -r owner size links < <(stat -c '%u %s %h' -- "$request")
        if [[ "$owner" != "$REQUEST_UID" || "$size" -gt 128 || "$links" != 1 ]]; then
            rm -f -- "$request"
            log_message "rejected unsafe request metadata from $requester"
            return 1
        fi
        mv -T -- "$request" "$claim" || return 1
    fi

    if [[ -L "$claim" || ! -f "$claim" ]]; then
        rm -f -- "$claim"
        log_message "rejected unsafe claimed request from $requester"
        return 1
    fi
    read -r owner size links < <(stat -c '%u %s %h' -- "$claim")
    if [[ "$owner" != "$REQUEST_UID" || "$size" -gt 128 || "$links" != 1 ]]; then
        rm -f -- "$claim"
        log_message "rejected claimed request metadata from $requester"
        return 1
    fi

    IFS= read -r request_id < "$claim" || request_id=
    request_id=${request_id//$'\r'/}
    if [[ ! "$request_id" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        rm -f -- "$claim"
        log_message "rejected malformed request identifier from $requester"
        return 1
    fi

    CLAIM_REQUESTER=$requester
    CLAIM_ID=$request_id
    CLAIM_FILE=$claim
    return 0
}

process_target() {
    local target=$1 stop_timeout=$2
    shift 2
    local requester entry outcome now last elapsed last_attempt_tmp
    local -a entries=()

    for requester in "$@"; do
        if claim_request "$requester"; then
            entries+=("$CLAIM_REQUESTER|$CLAIM_ID|$CLAIM_FILE")
        fi
    done
    (( ${#entries[@]} > 0 )) || return 0

    now=$(date +%s)
    last=0
    if [[ -r "$HOST_DIR/last-attempt.$target" ]]; then
        read -r last < "$HOST_DIR/last-attempt.$target" || last=0
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
    fi
    elapsed=$((now - last))

    if (( last > 0 && elapsed < MIN_RESTART_INTERVAL )); then
        outcome=deferred
        log_message "deferred $target restart; rate limit has $((MIN_RESTART_INTERVAL - elapsed))s remaining"
    else
        last_attempt_tmp="$HOST_DIR/.last-attempt.$$"
        printf '%s\n' "$now" > "$last_attempt_tmp"
        mv -fT -- "$last_attempt_tmp" "$HOST_DIR/last-attempt.$target"
        if "$TIMEOUT_BIN" --signal=KILL "$((stop_timeout + 30))" \
            "$DOCKER_BIN" restart -t "$stop_timeout" "$target" >/dev/null 2>&1; then
            outcome=ok
            log_message "restarted allowlisted target $target"
        else
            outcome=error
            log_message "failed to restart allowlisted target $target"
        fi
    fi

    write_p2pool_status
    for entry in "${entries[@]}"; do
        IFS='|' read -r requester CLAIM_ID CLAIM_FILE <<< "$entry"
        write_result "$requester" "$CLAIM_ID" "$outcome" "$target"
        rm -f -- "$CLAIM_FILE"
    done
}

check_installation() {
    local output status restarts updated age
    "$DOCKER_BIN" inspect salviumd salvium-p2pool >/dev/null
    write_p2pool_status
    read -r status restarts updated < "$STATUS_DIR/p2pool.state"
    age=$(( $(date +%s) - updated ))
    [[ "$status" != unknown && "$restarts" =~ ^[0-9]+$ && "$age" -le 5 ]] \
        || die "could not publish current P2Pool Docker status"
    printf 'PASS: restricted broker installation is healthy\n'
    printf 'P2Pool state: %s, restart count: %s\n' "$status" "$restarts"
}

case "${1:-run}" in
    run)
        write_p2pool_status
        process_target salviumd 120 salviumd-updater
        process_target salvium-p2pool 60 p2pool-updater p2pool-watchdog
        write_p2pool_status
        ;;
    status-only)
        write_p2pool_status
        ;;
    check)
        check_installation
        ;;
    *)
        die "usage: $0 [run|status-only|check]"
        ;;
esac

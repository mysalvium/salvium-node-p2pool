#!/bin/sh
# Shared client for the root-owned host broker. The caller can request only the
# action assigned to its bind-mounted directory; it cannot choose a Docker
# container or submit a host command.

BROKER_SEQUENCE=${BROKER_SEQUENCE:-0}

broker_restart() { # broker_restart <human-readable reason>
    _broker_dir=${BROKER_REQUEST_DIR:-/broker}
    _broker_timeout=${BROKER_REQUEST_TIMEOUT:-240}
    _broker_reason=${1:-unspecified}

    case "$_broker_timeout" in
        ''|*[!0-9]*)
            echo "[broker-client] invalid BROKER_REQUEST_TIMEOUT" >&2
            return 1
            ;;
    esac
    if [ ! -d "$_broker_dir" ] || [ ! -w "$_broker_dir" ]; then
        echo "[broker-client] request directory is unavailable: $_broker_dir" >&2
        return 1
    fi

    BROKER_SEQUENCE=$((BROKER_SEQUENCE + 1))
    _broker_id="$(date +%s)-$$-${BROKER_SEQUENCE}"
    _broker_tmp="$_broker_dir/.restart.request.$$"
    _broker_request="$_broker_dir/restart.request"
    _broker_result="$_broker_dir/restart.result"

    umask 077
    printf '%s\n' "$_broker_id" > "$_broker_tmp" || return 1
    mv -f "$_broker_tmp" "$_broker_request" || return 1
    echo "[broker-client] restart requested: $_broker_reason"

    _broker_started=$(date +%s)
    while [ $(( $(date +%s) - _broker_started )) -lt "$_broker_timeout" ]; do
        if [ -r "$_broker_result" ]; then
            IFS=' ' read -r _broker_result_id _broker_result_status _broker_result_rest < "$_broker_result" || true
            if [ "${_broker_result_id:-}" = "$_broker_id" ]; then
                case "${_broker_result_status:-}" in
                    ok)
                        echo "[broker-client] restricted host restart completed"
                        return 0
                        ;;
                    deferred)
                        echo "[broker-client] restart deferred by host rate limit" >&2
                        return 1
                        ;;
                    *)
                        echo "[broker-client] restricted host restart failed" >&2
                        return 1
                        ;;
                esac
            fi
        fi
        sleep 2
    done

    echo "[broker-client] timed out waiting for the host broker" >&2
    return 1
}

broker_read_p2pool_state() {
    _broker_state_file=${BROKER_STATUS_FILE:-/docker-status/p2pool.state}
    _broker_stale=${BROKER_STATUS_STALE:-180}

    BROKER_CONTAINER_STATUS=unknown
    BROKER_CONTAINER_RESTARTS=-1
    [ -r "$_broker_state_file" ] || return 1

    IFS=' ' read -r _broker_status _broker_restarts _broker_updated _broker_extra < "$_broker_state_file" || return 1

    case "$_broker_status" in
        created|restarting|running|removing|paused|exited|dead) ;;
        *) return 1 ;;
    esac
    case "$_broker_restarts" in ''|*[!0-9]*) return 1 ;; esac
    case "$_broker_updated" in ''|*[!0-9]*) return 1 ;; esac
    [ -z "$_broker_extra" ] || return 1
    case "$_broker_stale" in ''|*[!0-9]*) return 1 ;; esac
    [ $(( $(date +%s) - _broker_updated )) -le "$_broker_stale" ] || return 1

    BROKER_CONTAINER_STATUS=$_broker_status
    BROKER_CONTAINER_RESTARTS=$_broker_restarts
    return 0
}

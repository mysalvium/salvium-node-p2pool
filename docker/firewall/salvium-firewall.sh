#!/bin/sh
set -eu

CHAIN="SALVIUM-INGRESS"
HOST_CHAIN="SALVIUM-HOST-INGRESS"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"

TRUSTED_LAN_CIDRS="${TRUSTED_LAN_CIDRS:-192.168.1.0/24}"
RESTRICTED_RPC_EXTRA_CIDRS="${RESTRICTED_RPC_EXTRA_CIDRS:-}"
PRIVATE_P2POOL_CIDRS="${PRIVATE_P2POOL_CIDRS:-$TRUSTED_LAN_CIDRS}"
LAN_BIND_IP="${LAN_BIND_IP:-192.168.1.54}"

SALVIUM_RESTRICTED_RPC_PORT="${SALVIUM_RESTRICTED_RPC_PORT:-19089}"
P2POOL_STRATUM_PORT="${P2POOL_STRATUM_PORT:-3333}"
P2POOL_PRIVATE_P2P_PORT="${P2POOL_PRIVATE_P2P_PORT:-38888}"
STATS_PORT="${STATS_PORT:-3000}"

ipt() {
    iptables -w 10 "$@"
}

validate_port() {
    case "$2" in
        ''|*[!0-9]*) echo "ERROR: $1 must be a TCP port number." >&2; exit 1 ;;
    esac
    if [ "$2" -lt 1 ] || [ "$2" -gt 65535 ]; then
        echo "ERROR: $1 must be between 1 and 65535." >&2
        exit 1
    fi
}

add_sources() {
    port="$1"
    cidrs="$2"
    old_ifs=$IFS
    IFS=','
    for cidr in $cidrs; do
        cidr=$(printf '%s' "$cidr" | tr -d '[:space:]')
        [ -n "$cidr" ] || continue
        ipt -A "$CHAIN" -p tcp -s "$cidr" -m conntrack --ctdir ORIGINAL --ctorigdst "$LAN_BIND_IP" --ctorigdstport "$port" -j RETURN
    done
    IFS=$old_ifs
}

restrict_port() {
    port="$1"
    allowed="$2"
    add_sources "$port" "$allowed"
    ipt -A "$CHAIN" -p tcp -m conntrack --ctdir ORIGINAL --ctorigdst "$LAN_BIND_IP" --ctorigdstport "$port" -j DROP
}

add_host_sources() {
    port="$1"
    cidrs="$2"
    old_ifs=$IFS
    IFS=','
    for cidr in $cidrs; do
        cidr=$(printf '%s' "$cidr" | tr -d '[:space:]')
        [ -n "$cidr" ] || continue
        ipt -A "$HOST_CHAIN" -p tcp -s "$cidr" --dport "$port" -j RETURN
    done
    IFS=$old_ifs
}

restrict_host_port() {
    port="$1"
    allowed="$2"
    add_host_sources "$port" "$allowed"
    ipt -A "$HOST_CHAIN" -p tcp --dport "$port" -j DROP
}

apply_rules() {
    validate_port SALVIUM_RESTRICTED_RPC_PORT "$SALVIUM_RESTRICTED_RPC_PORT"
    validate_port P2POOL_STRATUM_PORT "$P2POOL_STRATUM_PORT"
    validate_port P2POOL_PRIVATE_P2P_PORT "$P2POOL_PRIVATE_P2P_PORT"
    validate_port STATS_PORT "$STATS_PORT"

    ipt -N "$CHAIN" 2>/dev/null || true
    ipt -F "$CHAIN"
    ipt -N "$HOST_CHAIN" 2>/dev/null || true
    ipt -F "$HOST_CHAIN"

    restrict_port "$SALVIUM_RESTRICTED_RPC_PORT" "${TRUSTED_LAN_CIDRS},${RESTRICTED_RPC_EXTRA_CIDRS}"
    restrict_port "$P2POOL_STRATUM_PORT" "$TRUSTED_LAN_CIDRS"
    restrict_port "$STATS_PORT" "$TRUSTED_LAN_CIDRS"
    restrict_port "$P2POOL_PRIVATE_P2P_PORT" "$PRIVATE_P2POOL_CIDRS"
    ipt -A "$CHAIN" -j RETURN

    # Connections from another local Docker bridge can reach docker-proxy via
    # the host address without traversing DOCKER-USER. Mirror the policy in
    # INPUT so network isolation cannot be bypassed through a host-bound port.
    restrict_host_port "$SALVIUM_RESTRICTED_RPC_PORT" "${TRUSTED_LAN_CIDRS},${RESTRICTED_RPC_EXTRA_CIDRS}"
    restrict_host_port "$P2POOL_STRATUM_PORT" "$TRUSTED_LAN_CIDRS"
    restrict_host_port "$STATS_PORT" "$TRUSTED_LAN_CIDRS"
    restrict_host_port "$P2POOL_PRIVATE_P2P_PORT" "$PRIVATE_P2POOL_CIDRS"
    ipt -A "$HOST_CHAIN" -j RETURN

    while ipt -C DOCKER-USER -j "$CHAIN" 2>/dev/null; do
        ipt -D DOCKER-USER -j "$CHAIN"
    done
    ipt -I DOCKER-USER 1 -j "$CHAIN"

    while ipt -C INPUT -j "$HOST_CHAIN" 2>/dev/null; do
        ipt -D INPUT -j "$HOST_CHAIN"
    done
    ipt -I INPUT 1 -j "$HOST_CHAIN"
}

check_rules() {
    ipt -C DOCKER-USER -j "$CHAIN" >/dev/null 2>&1
    ipt -C INPUT -j "$HOST_CHAIN" >/dev/null 2>&1
    ipt -C "$CHAIN" -p tcp -m conntrack --ctdir ORIGINAL --ctorigdst "$LAN_BIND_IP" --ctorigdstport "$SALVIUM_RESTRICTED_RPC_PORT" -j DROP >/dev/null 2>&1
    ipt -C "$CHAIN" -p tcp -m conntrack --ctdir ORIGINAL --ctorigdst "$LAN_BIND_IP" --ctorigdstport "$P2POOL_STRATUM_PORT" -j DROP >/dev/null 2>&1
    ipt -C "$CHAIN" -p tcp -m conntrack --ctdir ORIGINAL --ctorigdst "$LAN_BIND_IP" --ctorigdstport "$STATS_PORT" -j DROP >/dev/null 2>&1
    ipt -C "$CHAIN" -p tcp -m conntrack --ctdir ORIGINAL --ctorigdst "$LAN_BIND_IP" --ctorigdstport "$P2POOL_PRIVATE_P2P_PORT" -j DROP >/dev/null 2>&1
    ipt -C "$HOST_CHAIN" -p tcp --dport "$SALVIUM_RESTRICTED_RPC_PORT" -j DROP >/dev/null 2>&1
    ipt -C "$HOST_CHAIN" -p tcp --dport "$P2POOL_STRATUM_PORT" -j DROP >/dev/null 2>&1
    ipt -C "$HOST_CHAIN" -p tcp --dport "$STATS_PORT" -j DROP >/dev/null 2>&1
    ipt -C "$HOST_CHAIN" -p tcp --dport "$P2POOL_PRIVATE_P2P_PORT" -j DROP >/dev/null 2>&1
}

remove_rules() {
    while ipt -C DOCKER-USER -j "$CHAIN" 2>/dev/null; do
        ipt -D DOCKER-USER -j "$CHAIN"
    done
    while ipt -C INPUT -j "$HOST_CHAIN" 2>/dev/null; do
        ipt -D INPUT -j "$HOST_CHAIN"
    done
    ipt -F "$CHAIN" 2>/dev/null || true
    ipt -X "$CHAIN" 2>/dev/null || true
    ipt -F "$HOST_CHAIN" 2>/dev/null || true
    ipt -X "$HOST_CHAIN" 2>/dev/null || true
}

case "${1:-run}" in
    check)
        check_rules
        ;;
    apply)
        apply_rules
        ;;
    remove)
        remove_rules
        ;;
    run)
        apply_rules
        echo "Salvium Docker ingress policy installed in DOCKER-USER."
        while :; do
            sleep "$CHECK_INTERVAL" &
            wait $!
            if ! check_rules; then
                echo "Salvium ingress policy was missing; restoring it." >&2
                apply_rules
            fi
        done
        ;;
    *)
        echo "Usage: salvium-firewall [run|apply|check|remove]" >&2
        exit 2
        ;;
esac

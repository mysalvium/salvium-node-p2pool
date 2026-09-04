#!/usr/bin/env bash
# Start disposable public and private P2Pool instances without SYS_ADMIN.
# No host port is published and production data is never mounted writable.
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
ENV_FILE=${1:-$REPO_DIR/.env}
TEST_PARENT=${TEST_PARENT:-/tmp}
CONTAINER=salvium-p2pool-privilege-test

die() { printf 'p2pool privilege test: %s\n' "$*" >&2; exit 1; }
read_env_value() {
    local key=$1 default=$2 value
    value=$(sed -n "s/^${key}=//p" "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d '\r')
    printf '%s' "${value:-$default}"
}

[[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"
[[ -d "$TEST_PARENT" && -w "$TEST_PARENT" ]] || die "TEST_PARENT must be writable"
command -v docker >/dev/null || die "docker is required"

DATA_ROOT=$(read_env_value SALVIUM_DATA_ROOT "")
APP_ROOT=$(read_env_value SALVIUM_APP_ROOT "")
PUID=$(read_env_value PUID 1000)
PGID=$(read_env_value PGID 1000)
IMAGE=$(read_env_value P2POOL_IMAGE p2pool-salvium:local)
NETWORK=$(read_env_value SALVIUM_NODE_NETWORK salvium_node)
WALLET=$(read_env_value P2POOL_WALLET "")
MEMORY_LIMIT=$(read_env_value P2POOL_MEMORY_LIMIT 4192M)
CPU_LIMIT=$(read_env_value P2POOL_CPUS 2.0)
[[ "$DATA_ROOT" =~ ^/[A-Za-z0-9._/-]+$ && "$APP_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid app/data path"
[[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]] || die "invalid PUID/PGID"
[[ -n "$WALLET" && "$WALLET" != replace-with-* ]] || die "P2POOL_WALLET is not configured"
docker image inspect "$IMAGE" >/dev/null || die "P2Pool image is missing: $IMAGE"
docker network inspect "$NETWORK" >/dev/null || die "node network is missing: $NETWORK"

TEST_ROOT=$(mktemp -d "$TEST_PARENT/salvium-p2pool-privilege-test.XXXXXX")
cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    resolved=$(readlink -f -- "$TEST_ROOT" 2>/dev/null || true)
    if [[ "$resolved" == "$TEST_PARENT"/salvium-p2pool-privilege-test.* ]]; then
        rm -rf -- "$resolved"
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT/p2pool/public" "$TEST_ROOT/p2pool/private" "$TEST_ROOT/stats" "$TEST_ROOT/control"
cp -a "$DATA_ROOT/p2pool/bin" "$TEST_ROOT/p2pool/"
[[ -f "$DATA_ROOT/p2pool/sidechain.json" ]] && cp -p "$DATA_ROOT/p2pool/sidechain.json" "$TEST_ROOT/p2pool/"
if [[ -d "$DATA_ROOT/p2pool/public" ]]; then
    cp -a "$DATA_ROOT/p2pool/public/." "$TEST_ROOT/p2pool/public/"
fi
if [[ -d "$DATA_ROOT/p2pool/private" ]]; then
    cp -a "$DATA_ROOT/p2pool/private/." "$TEST_ROOT/p2pool/private/"
fi
chown -R "$PUID:$PGID" "$TEST_ROOT"

run_mode() {
    local mode=$1 deadline state connections=0 logs
    printf '%s\n' "$mode" > "$TEST_ROOT/control/active"
    chown "$PUID:$PGID" "$TEST_ROOT/control/active"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" \
        --network "$NETWORK" --user "$PUID:$PGID" \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m \
        --tmpfs /run:rw,noexec,nosuid,nodev,size=16m \
        --cap-drop ALL --cap-add IPC_LOCK --security-opt no-new-privileges:true \
        --pids-limit 1024 --memory "$MEMORY_LIMIT" --cpus "$CPU_LIMIT" \
        -e P2POOL_TEST_WALLET="$WALLET" \
        -v "$TEST_ROOT/p2pool:/home/p2pool/.p2pool:rw" \
        -v "$TEST_ROOT/stats:/home/p2pool/stats:rw" \
        -v "$TEST_ROOT/control:/control:ro" \
        -v "$APP_ROOT/ops/switch-entrypoint.sh:/ops/switch-entrypoint.sh:ro" \
        -v /dev/hugepages:/dev/hugepages:rw \
        --entrypoint /bin/sh "$IMAGE" -c \
        'mkdir -p /tmp/ops && tr -d "\r" < /ops/switch-entrypoint.sh > /tmp/ops/switch-entrypoint.sh && exec /bin/bash /tmp/ops/switch-entrypoint.sh --host salviumd --rpc-port 19089 --zmq-port 19083 --log-file /dev/stdout --wallet "$P2POOL_TEST_WALLET" --stratum 0.0.0.0:3333 --data-api /home/p2pool/stats --stratum-api --no-igd' >/dev/null

    deadline=$(( $(date +%s) + 180 ))
    while (( $(date +%s) < deadline )); do
        state=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)
        [[ "$state" = running ]] || { docker logs --tail 80 "$CONTAINER" >&2 || true; die "$mode test container exited"; }
        if [[ -r "$TEST_ROOT/stats/local/p2p" ]]; then
            connections=$(sed -n 's/.*"connections"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$TEST_ROOT/stats/local/p2p" | head -n 1)
            connections=${connections:-0}
            break
        fi
        sleep 5
    done
    [[ -r "$TEST_ROOT/stats/local/p2p" ]] || die "$mode test produced no P2Pool statistics"

    # A disposable instance may be rejected as a duplicate by peers while the
    # production pool is still online. Prove node connectivity and useful pool
    # startup instead of making outside peer availability a privilege test.
    sleep 10
    state=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)
    [[ "$state" = running ]] || { docker logs --tail 80 "$CONTAINER" >&2 || true; die "$mode test container exited"; }
    logs=$(docker logs --tail 300 "$CONTAINER" 2>&1 || true)
    grep -Eq 'StratumServer|BlockTemplate|SideChain (verified block|new chain tip)' <<<"$logs" \
        || { printf '%s\n' "$logs" >&2; die "$mode test did not reach pool initialization"; }
    if grep -Eqi 'permission denied|read-only file system' <<<"$logs"; then
        printf '%s\n' "$logs" >&2
        die "$mode test hit a filesystem privilege error"
    fi

    security=$(docker inspect "$CONTAINER" --format '{{.HostConfig.ReadonlyRootfs}}|{{json .HostConfig.CapAdd}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.SecurityOpt}}')
    [[ "$security" == true* && "$security" == *CAP_IPC_LOCK* && "$security" != *CAP_SYS_ADMIN* && "$security" == *'"ALL"'* && "$security" == *no-new-privileges* ]] \
        || die "$mode test did not retain the reduced privilege boundary"
    printf 'PASS: %s P2Pool starts, talks to salviumd, and produces statistics without SYS_ADMIN (peers observed: %s)\n' "$mode" "$connections"
}

run_mode public
run_mode private

#!/usr/bin/env bash
# Isolated tests for the restricted broker. The fake Docker executable records
# requested operations; this test never contacts the real Docker daemon.
set -Eeuo pipefail

[[ $(id -u) -eq 0 ]] || { echo "SKIP: broker isolation test requires root"; exit 77; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
TEST_PARENT=${TEST_PARENT:-/tmp}
[[ -d "$TEST_PARENT" && -w "$TEST_PARENT" ]] || { echo "error: TEST_PARENT must be writable" >&2; exit 1; }
TEST_ROOT=$(mktemp -d "$TEST_PARENT/salvium-broker-test.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

HOST_DIR="$TEST_ROOT/host"
REQUEST_ROOT="$TEST_ROOT/requests"
STATUS_DIR="$TEST_ROOT/status"
FAKE_LOG="$TEST_ROOT/fake-docker.log"
mkdir -p "$HOST_DIR" "$STATUS_DIR" \
    "$REQUEST_ROOT/salviumd-updater" \
    "$REQUEST_ROOT/p2pool-updater" \
    "$REQUEST_ROOT/p2pool-watchdog"
chmod 0700 "$HOST_DIR"
chmod 0755 "$STATUS_DIR"

install -m 0700 -o root -g root "$REPO_DIR/ops/salvium-docker-broker.sh" \
    "$HOST_DIR/salvium-docker-broker.sh"

FAKE_DOCKER="$TEST_ROOT/fake-docker"
cat > "$FAKE_DOCKER" <<'EOF'
#!/bin/sh
case "$1" in
    inspect)
        case " $* " in
            *" --format "*) printf 'running 7\n' ;;
        esac
        exit 0
        ;;
    restart)
        printf '%s\n' "$*" >> "$FAKE_LOG"
        exit 0
        ;;
    *) exit 64 ;;
esac
EOF
chmod 0700 "$FAKE_DOCKER"
export FAKE_LOG

cat > "$HOST_DIR/broker.conf" <<EOF
REQUEST_UID=0
MIN_RESTART_INTERVAL=0
DOCKER_BIN=$FAKE_DOCKER
TIMEOUT_BIN=/usr/bin/timeout
LOGGER_BIN=/usr/bin/true
EOF
chmod 0600 "$HOST_DIR/broker.conf"

BROKER="$HOST_DIR/salvium-docker-broker.sh"
printf 'node-1\n' > "$REQUEST_ROOT/salviumd-updater/restart.request"
printf 'pool-update-1\n' > "$REQUEST_ROOT/p2pool-updater/restart.request"
printf 'pool-watchdog-1\n' > "$REQUEST_ROOT/p2pool-watchdog/restart.request"
/usr/bin/bash "$BROKER" run

[[ $(grep -c '^restart ' "$FAKE_LOG") -eq 2 ]]
[[ $(grep -c 'salviumd$' "$FAKE_LOG") -eq 1 ]]
[[ $(grep -c 'salvium-p2pool$' "$FAKE_LOG") -eq 1 ]]
grep -q '^node-1 ok salviumd ' "$REQUEST_ROOT/salviumd-updater/restart.result"
grep -q '^pool-update-1 ok salvium-p2pool ' "$REQUEST_ROOT/p2pool-updater/restart.result"
grep -q '^pool-watchdog-1 ok salvium-p2pool ' "$REQUEST_ROOT/p2pool-watchdog/restart.result"
echo "PASS: requests are mapped to fixed targets and duplicate P2Pool requests are coalesced"

before=$(wc -l < "$FAKE_LOG")
ln -s /etc/passwd "$REQUEST_ROOT/salviumd-updater/restart.request"
/usr/bin/bash "$BROKER" run
[[ $(wc -l < "$FAKE_LOG") -eq "$before" ]]
[[ ! -e "$REQUEST_ROOT/salviumd-updater/restart.request" ]]
printf 'bad identifier with spaces\n' > "$REQUEST_ROOT/p2pool-updater/restart.request"
/usr/bin/bash "$BROKER" run
[[ $(wc -l < "$FAKE_LOG") -eq "$before" ]]
echo "PASS: symlink and malformed requests are rejected without contacting Docker"

sed -i 's/^MIN_RESTART_INTERVAL=0$/MIN_RESTART_INTERVAL=300/' "$HOST_DIR/broker.conf"
date +%s > "$HOST_DIR/last-attempt.salvium-p2pool"
printf 'rate-limit-1\n' > "$REQUEST_ROOT/p2pool-watchdog/restart.request"
/usr/bin/bash "$BROKER" run
[[ $(wc -l < "$FAKE_LOG") -eq "$before" ]]
grep -q '^rate-limit-1 deferred salvium-p2pool ' "$REQUEST_ROOT/p2pool-watchdog/restart.result"
sed -i 's/^MIN_RESTART_INTERVAL=300$/MIN_RESTART_INTERVAL=0/' "$HOST_DIR/broker.conf"
echo "PASS: the per-target restart rate limit fails closed"

grep -Eq '^running 7 [0-9]+$' "$STATUS_DIR/p2pool.state"
BROKER_STATUS_FILE="$STATUS_DIR/p2pool.state"
BROKER_STATUS_STALE=180
# shellcheck disable=SC1090
. "$REPO_DIR/ops/request-docker-restart.sh"
broker_read_p2pool_state
[[ "$BROKER_CONTAINER_STATUS" = running && "$BROKER_CONTAINER_RESTARTS" = 7 ]]
echo "PASS: the watchdog reads a validated, fresh status snapshot"

(
    BROKER_REQUEST_DIR="$REQUEST_ROOT/p2pool-watchdog"
    BROKER_REQUEST_TIMEOUT=10
    # shellcheck disable=SC1090
    . "$REPO_DIR/ops/request-docker-restart.sh"
    broker_restart "isolated client test"
) &
client_pid=$!
for _ in $(seq 1 20); do
    [[ -f "$REQUEST_ROOT/p2pool-watchdog/restart.request" ]] && break
    sleep 0.1
done
[[ -f "$REQUEST_ROOT/p2pool-watchdog/restart.request" ]]
/usr/bin/bash "$BROKER" run
wait "$client_pid"
echo "PASS: the unprivileged client request/acknowledgement protocol works"

echo "All restricted Docker broker tests passed."

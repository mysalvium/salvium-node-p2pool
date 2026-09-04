#!/usr/bin/env bash
###############################################################################
#  build-images.sh
#
#  Builds the images used by this repository locally.
#  Run this BEFORE deploying the stack in Portainer.
#
#  Usage:
#    ./scripts/build-images.sh
#
#  Validate compose.yaml before deploying it.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_DIR/docker"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
SALVIUMD_IMAGE="${SALVIUMD_IMAGE:-salviumd:local}"
P2POOL_IMAGE="${P2POOL_IMAGE:-p2pool-salvium:local}"
STATS_IMAGE="${STATS_IMAGE:-salvium-stats:local}"
FIREWALL_IMAGE="${FIREWALL_IMAGE:-salvium-firewall:local}"
STATS_SOURCE_COMMIT="${STATS_SOURCE_COMMIT:-a0fed9e186fa85d16eefdaf62bd6dbecadb629af}"

G='\033[0;32m'; Y='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${G}[BUILD]${NC} $*"; }
warn()  { echo -e "${Y}[BUILD]${NC} $*"; }

echo ""
echo "============================================================"
echo "  Building Salvium Docker Images"
echo "============================================================"
echo ""

# ── salviumd ────────────────────────────────────────────────────────────────
info "Building ${SALVIUMD_IMAGE} ..."
docker build -t "$SALVIUMD_IMAGE" "$BUILD_DIR/salviumd"

# ── p2pool-salvium ──────────────────────────────────────────────────────────
info "Building ${P2POOL_IMAGE} ..."
docker build -t "$P2POOL_IMAGE" "$BUILD_DIR/p2pool"

# ── salvium-stats ───────────────────────────────────────────────────────────
info "Building ${STATS_IMAGE} ..."
docker build --build-arg "STATS_SOURCE_COMMIT=$STATS_SOURCE_COMMIT" -t "$STATS_IMAGE" "$BUILD_DIR/stats"

# ── host ingress policy ─────────────────────────────────────────────────────
info "Building ${FIREWALL_IMAGE} ..."
docker build -t "$FIREWALL_IMAGE" "$BUILD_DIR/firewall"

echo ""
info "All images built:"
docker images --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'salvium|p2pool'
echo ""
info "Run: docker compose --env-file .env config"
echo ""

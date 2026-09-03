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

G='\033[0;32m'; Y='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${G}[BUILD]${NC} $*"; }
warn()  { echo -e "${Y}[BUILD]${NC} $*"; }

echo ""
echo "============================================================"
echo "  Building Salvium Docker Images"
echo "============================================================"
echo ""

# ── salviumd ────────────────────────────────────────────────────────────────
info "Building salviumd:local ..."
docker build -t salviumd:local "$BUILD_DIR/salviumd"

# ── p2pool-salvium ──────────────────────────────────────────────────────────
info "Building p2pool-salvium:local ..."
docker build -t p2pool-salvium:local "$BUILD_DIR/p2pool"

# ── salvium-stats ───────────────────────────────────────────────────────────
info "Building salvium-stats:local ..."
docker build -t salvium-stats:local "$BUILD_DIR/stats"

echo ""
info "All images built:"
docker images --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'salvium|p2pool'
echo ""
info "Run: docker compose --env-file .env config"
echo ""

#!/usr/bin/env bash
# Reproducible source, configuration, image-vulnerability, and SBOM scan.
# Trivy runs as a host process and never receives the Docker socket in a
# container. The scanner archive itself is pinned and SHA-256 verified.
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
ENV_FILE=${1:-$REPO_DIR/.env.example}
MODE=${2:-full}
TRIVY_VERSION=0.74.0
TRIVY_SHA256=2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a
TRIVY_URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
CACHE_DIR=${SECURITY_CACHE_DIR:-$REPO_DIR/.security-cache}
TOOL_DIR="$CACHE_DIR/trivy-${TRIVY_VERSION}"
REPORT_DIR=${SECURITY_REPORT_DIR:-$REPO_DIR/.security-reports}
TRIVY="$TOOL_DIR/trivy"

die() { printf 'security-scan: %s\n' "$*" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"
[[ $(uname -m) = x86_64 ]] || die "the pinned scanner artifact currently supports x86_64 only"
command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
command -v tar >/dev/null || die "tar is required"

read_env_value() {
    local key=$1 default=$2 value
    value=$(sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r')
    printf '%s' "${value:-$default}"
}

mkdir -p "$CACHE_DIR" "$REPORT_DIR"
if [[ ! -x "$TRIVY" ]]; then
    archive=$(mktemp "$CACHE_DIR/.trivy.XXXXXX")
    extract=$(mktemp -d "$CACHE_DIR/.trivy-extract.XXXXXX")
    cleanup_download() { rm -f -- "$archive"; rm -rf -- "$extract"; }
    trap cleanup_download EXIT INT TERM
    curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 180 -o "$archive" "$TRIVY_URL"
    actual=$(sha256sum "$archive" | awk '{print tolower($1)}')
    [[ "$actual" = "$TRIVY_SHA256" ]] || die "Trivy archive checksum mismatch"
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$extract" trivy
    mkdir -p "$TOOL_DIR"
    install -m 0755 "$extract/trivy" "$TOOL_DIR/.trivy.new"
    mv -fT -- "$TOOL_DIR/.trivy.new" "$TRIVY"
    cleanup_download
    trap - EXIT INT TERM
fi

"$TRIVY" --version
"$TRIVY" fs --scanners secret --exit-code 1 --quiet \
    --skip-dirs "$REPO_DIR/.git" --skip-dirs "$CACHE_DIR" --skip-dirs "$REPORT_DIR" \
    --skip-files "$REPO_DIR/.env" --skip-files "$REPO_DIR/.portainer-token" \
    "$REPO_DIR"

"$TRIVY" config --exit-code 0 --format json --output "$REPORT_DIR/config.json" "$REPO_DIR"
"$TRIVY" fs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
    --exit-code 0 --format json --output "$REPORT_DIR/source-vulnerabilities.json" "$REPO_DIR"
printf 'PASS: source secret scan; configuration and dependency reports written\n'

[[ "$MODE" = source-only ]] && exit 0
[[ "$MODE" = full ]] || die "mode must be full or source-only"
command -v docker >/dev/null || die "docker is required for image scanning"

images=(
    "$(read_env_value SALVIUMD_IMAGE salviumd:local)"
    "$(read_env_value P2POOL_IMAGE p2pool-salvium:local)"
    "$(read_env_value STATS_IMAGE salvium-stats:local)"
    "$(read_env_value FIREWALL_IMAGE salvium-firewall:local)"
    "$(read_env_value MANAGEMENT_IMAGE salvium-management:local)"
)

for image in "${images[@]}"; do
    docker image inspect "$image" >/dev/null 2>&1 || die "image is not available locally: $image"
    safe_name=$(printf '%s' "$image" | tr '/:@' '____')
    "$TRIVY" image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
        --exit-code 0 --format json --output "$REPORT_DIR/${safe_name}.vulnerabilities.json" "$image"
    "$TRIVY" image --scanners vuln --severity CRITICAL --ignore-unfixed \
        --exit-code 1 --format table "$image"
    "$TRIVY" image --format spdx-json --output "$REPORT_DIR/${safe_name}.spdx.json" "$image"
done

printf 'PASS: all images have SBOMs and no fixable CRITICAL vulnerability\n'

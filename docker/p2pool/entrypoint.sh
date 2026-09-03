#!/bin/bash
set -eu

# GitLab project: whiskyrelaxing-group/p2pool-salvium-releases
PROJECT_ID="whiskyrelaxing-group%2Fp2pool-salvium-releases"
RELEASES_API="https://gitlab.com/api/v4/projects/${PROJECT_ID}/releases"
BINARY="/home/p2pool/.p2pool/bin/p2pool-salvium"
VERSION_FILE="/home/p2pool/.p2pool/bin/.current_version"

mkdir -p /home/p2pool/.p2pool/bin

echo "==> Checking for p2pool-salvium updates..."

# Fetch latest release tag from GitLab API
LATEST_TAG=""
if command -v curl >/dev/null && command -v jq >/dev/null; then
    LATEST_TAG=$(curl -sf --max-time 15 "${RELEASES_API}" \
        | jq -r '.[0].tag_name // empty') || true
fi

LOCAL_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    LOCAL_VERSION=$(cat "$VERSION_FILE")
fi

NEED_UPDATE=0
if [ ! -f "$BINARY" ]; then
    echo "==> No binary found. Downloading..."
    NEED_UPDATE=1
elif [ -z "$LATEST_TAG" ]; then
    echo "==> Could not reach GitLab API; using existing binary."
elif [ "$LATEST_TAG" != "$LOCAL_VERSION" ]; then
    echo "==> New version detected: ${LATEST_TAG} (current: ${LOCAL_VERSION:-none}). Updating..."
    NEED_UPDATE=1
else
    echo "==> Binary is up to date (${LOCAL_VERSION})."
fi

if [ "$NEED_UPDATE" -eq 1 ]; then
    if [ -z "$LATEST_TAG" ]; then
        # API unreachable but no binary — retry with longer timeout
        echo "==> API unreachable and no binary. Retrying..."
        LATEST_TAG=$(curl -sf --max-time 30 "${RELEASES_API}" \
            | jq -r '.[0].tag_name // empty') || true
        if [ -z "$LATEST_TAG" ]; then
            echo "==> FATAL: Cannot reach GitLab API and no existing binary."
            exit 1
        fi
    fi

    # Find the linux-x64-static asset URL from the release
    echo "==> Fetching release ${LATEST_TAG} asset list..."
    DOWNLOAD_URL=$(curl -sf --max-time 15 \
        "${RELEASES_API}/${LATEST_TAG}" \
        | jq -r '.assets.links[]? | select(.name | test("Linux x64 \\(static"; "i")) | .direct_asset_url // .url' \
        | head -n 1) || true

    if [ -z "$DOWNLOAD_URL" ]; then
        echo "==> ERROR: Could not find linux-x64 download URL for ${LATEST_TAG}"
        echo "==> Available release assets:"
        curl -sf "${RELEASES_API}/${LATEST_TAG}" | jq '.assets.links[]?.name' || true
        if [ -f "$BINARY" ]; then
            echo "==> Falling back to existing binary."
        else
            exit 1
        fi
    else
        echo "==> Downloading: ${DOWNLOAD_URL}"
        TMPDIR=$(mktemp -d)
        curl -fSL --max-time 120 -o "${TMPDIR}/p2pool.tar.gz" "$DOWNLOAD_URL"

        echo "==> Extracting..."
        tar xzf "${TMPDIR}/p2pool.tar.gz" -C "${TMPDIR}"

        # Find the p2pool binary in the extracted files
        P2POOL_BIN=$(find "${TMPDIR}" -type f -name 'p2pool*' ! -name '*.tar.gz' ! -name '*.txt' ! -name '*.md' | head -n 1)

        if [ -z "$P2POOL_BIN" ]; then
            echo "==> ERROR: Could not find p2pool binary in archive. Contents:"
            find "${TMPDIR}" -type f
            rm -rf "${TMPDIR}"
            if [ -f "$BINARY" ]; then
                echo "==> Falling back to existing binary."
            else
                exit 1
            fi
        else
            echo "==> Installing: $(basename "$P2POOL_BIN") -> ${BINARY}"
            cp -f "$P2POOL_BIN" "$BINARY"
            chmod 755 "$BINARY"
            echo "$LATEST_TAG" > "$VERSION_FILE"
            rm -rf "${TMPDIR}"
            echo "==> Update complete (${LATEST_TAG})."
        fi
    fi
fi

echo "==> Starting p2pool-salvium..."
exec "$BINARY" "$@"

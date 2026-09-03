#!/bin/bash
set -eu

# GitHub repo: salvium/salvium
RELEASES_API="https://api.github.com/repos/salvium/salvium/releases/latest"
BINARY="/home/salvium/bin/salviumd"
VERSION_FILE="/home/salvium/bin/.current_version"

mkdir -p /home/salvium/bin

echo "==> Checking for salviumd updates..."

# Fetch latest release tag from GitHub API
LATEST_TAG=""
if command -v curl >/dev/null && command -v jq >/dev/null; then
    LATEST_TAG=$(curl -sf --max-time 15 "${RELEASES_API}" \
        | jq -r '.tag_name // empty') || true
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
    echo "==> Could not reach GitHub API; using existing binary."
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
            | jq -r '.tag_name // empty') || true
        if [ -z "$LATEST_TAG" ]; then
            echo "==> FATAL: Cannot reach GitHub API and no existing binary."
            exit 1
        fi
    fi

    # Find the ubuntu22.04 linux x86_64 zip asset from the release
    echo "==> Fetching release ${LATEST_TAG} asset list..."
    DOWNLOAD_URL=$(curl -sf --max-time 15 "${RELEASES_API}" \
        | jq -r '.assets[]? | select(.name | test("ubuntu22\\.04.*linux.*x86_64.*\\.zip$"; "i")) | .browser_download_url' \
        | head -n 1) || true

    if [ -z "$DOWNLOAD_URL" ]; then
        echo "==> ERROR: Could not find ubuntu22.04 linux x86_64 download URL for ${LATEST_TAG}"
        echo "==> Available release assets:"
        curl -sf --max-time 15 "${RELEASES_API}" | jq '.assets[]?.name' || true
        if [ -f "$BINARY" ]; then
            echo "==> Falling back to existing binary."
        else
            exit 1
        fi
    else
        echo "==> Downloading: ${DOWNLOAD_URL}"
        TMPDIR=$(mktemp -d)
        curl -fSL --max-time 120 -o "${TMPDIR}/salvium.zip" "$DOWNLOAD_URL"

        echo "==> Extracting..."
        unzip -q "${TMPDIR}/salvium.zip" -d "${TMPDIR}"

        # Find the salviumd binary in the extracted files
        SALVIUMD_BIN=$(find "${TMPDIR}" -type f -name 'salviumd' | head -n 1)

        if [ -z "$SALVIUMD_BIN" ]; then
            echo "==> ERROR: Could not find salviumd binary in archive. Contents:"
            find "${TMPDIR}" -type f
            rm -rf "${TMPDIR}"
            if [ -f "$BINARY" ]; then
                echo "==> Falling back to existing binary."
            else
                exit 1
            fi
        else
            echo "==> Installing: $(basename "$SALVIUMD_BIN") -> ${BINARY}"
            cp -f "$SALVIUMD_BIN" "$BINARY"
            chmod 755 "$BINARY"
            echo "$LATEST_TAG" > "$VERSION_FILE"
            rm -rf "${TMPDIR}"
            echo "==> Update complete (${LATEST_TAG})."
        fi
    fi
fi

echo "==> Starting salviumd..."
exec "$BINARY" --non-interactive "$@"

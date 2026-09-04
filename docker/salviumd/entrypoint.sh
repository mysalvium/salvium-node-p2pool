#!/bin/bash
set -eu
umask 022

# GitHub repo: salvium/salvium
RELEASES_API="https://api.github.com/repos/salvium/salvium/releases/latest"
BINARY="/home/salvium/bin/salviumd"
VERSION_FILE="/home/salvium/bin/.current_version"
PREVIOUS_BINARY="${BINARY}.previous"
VERIFY_RELEASE_ONLY="${VERIFY_RELEASE_ONLY:-0}"

RELEASE_JSON=""
LATEST_TAG=""
TMPDIR=""

cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fetch_release() {
    RELEASE_JSON=$(curl -sf --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --max-time 30 "$RELEASES_API") || RELEASE_JSON=""
    if [ -n "$RELEASE_JSON" ]; then
        LATEST_TAG=$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name // empty' 2>/dev/null) || LATEST_TAG=""
    else
        LATEST_TAG=""
    fi
}

fallback_or_fail() {
    echo "==> ERROR: $1" >&2
    cleanup
    TMPDIR=""
    if [ -x "$BINARY" ]; then
        echo "==> Update rejected; continuing with the existing installed binary."
        return 0
    fi
    echo "==> FATAL: No existing binary is available." >&2
    return 1
}

expected_sha_from_release() {
    local asset_name=$1
    printf '%s' "$RELEASE_JSON" \
        | jq -r --arg file "$asset_name" '(.body // "") | split("\n")[] | select(contains($file))' 2>/dev/null \
        | grep -Eo '[A-Fa-f0-9]{64}' \
        | head -n 1 \
        | tr '[:upper:]' '[:lower:]'
}

atomic_install() {
    local source_binary=$1
    local new_binary="${BINARY}.new.$$"
    local new_previous="${PREVIOUS_BINARY}.new.$$"
    local new_version="${VERSION_FILE}.new.$$"

    rm -f "$new_binary" "$new_previous" "$new_version"
    if ! install -m 0755 "$source_binary" "$new_binary"; then
        rm -f "$new_binary" "$new_previous" "$new_version"
        return 1
    fi
    if ! printf '%s\n' "$LATEST_TAG" > "$new_version"; then
        rm -f "$new_binary" "$new_previous" "$new_version"
        return 1
    fi

    if [ -f "$BINARY" ]; then
        if ! cp -p "$BINARY" "$new_previous" || ! mv -f "$new_previous" "$PREVIOUS_BINARY"; then
            rm -f "$new_binary" "$new_previous" "$new_version"
            return 1
        fi
    fi

    # Both paths are in the persistent bin directory, so rename is atomic.
    if ! mv -f "$new_binary" "$BINARY"; then
        rm -f "$new_binary" "$new_version"
        return 1
    fi
    if ! mv -f "$new_version" "$VERSION_FILE"; then
        echo "==> WARNING: Binary installed, but its version marker could not be updated." >&2
        rm -f "$new_version"
    fi
    return 0
}

install_release() {
    local asset_json asset_name download_url expected_sha archive extract_dir actual_sha salviumd_bin
    asset_json=$(printf '%s' "$RELEASE_JSON" | jq -c \
        '[.assets[]? | select(.name | test("ubuntu22\\.04.*linux.*x86_64.*\\.zip$"; "i"))][0] // empty' \
        2>/dev/null) || asset_json=""
    asset_name=$(printf '%s' "$asset_json" | jq -r '.name // empty' 2>/dev/null) || asset_name=""
    download_url=$(printf '%s' "$asset_json" | jq -r '.browser_download_url // empty' 2>/dev/null) || download_url=""

    if [ -z "$asset_name" ] || [ -z "$download_url" ]; then
        fallback_or_fail "Could not identify the Ubuntu x86_64 asset for ${LATEST_TAG}."
        return $?
    fi

    expected_sha=$(expected_sha_from_release "$asset_name") || expected_sha=""
    if [ ${#expected_sha} -ne 64 ]; then
        fallback_or_fail "No valid SHA-256 checksum was published for ${asset_name}."
        return $?
    fi

    TMPDIR=$(mktemp -d)
    archive="${TMPDIR}/${asset_name}"
    extract_dir="${TMPDIR}/extract"
    mkdir -p "$extract_dir"

    echo "==> Downloading ${asset_name}..."
    if ! curl -fSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --max-time 120 -o "$archive" "$download_url"; then
        fallback_or_fail "Download failed for ${asset_name}."
        return $?
    fi

    actual_sha=$(sha256sum "$archive" | awk '{print tolower($1)}')
    if [ "$actual_sha" != "$expected_sha" ]; then
        fallback_or_fail "SHA-256 mismatch for ${asset_name}; expected ${expected_sha}, received ${actual_sha}."
        return $?
    fi
    echo "==> SHA-256 verified: ${actual_sha}"

    if ! unzip -q "$archive" -d "$extract_dir"; then
        fallback_or_fail "Verified archive could not be extracted."
        return $?
    fi
    salviumd_bin=$(find "$extract_dir" -type f -name 'salviumd' | head -n 1)
    if [ -z "$salviumd_bin" ]; then
        fallback_or_fail "Verified archive did not contain salviumd."
        return $?
    fi

    if [ "$VERIFY_RELEASE_ONLY" = "1" ]; then
        cleanup
        TMPDIR=""
        echo "==> Release ${LATEST_TAG} passed checksum, archive, and binary-content verification."
        return 0
    fi

    if ! atomic_install "$salviumd_bin"; then
        fallback_or_fail "Atomic installation failed."
        return $?
    fi

    cleanup
    TMPDIR=""
    if [ -f "$PREVIOUS_BINARY" ]; then
        echo "==> Update complete (${LATEST_TAG}); previous binary retained at ${PREVIOUS_BINARY}."
    else
        echo "==> Verified installation complete (${LATEST_TAG})."
    fi
    return 0
}

echo "==> Checking for salviumd updates..."
fetch_release

if [ "$VERIFY_RELEASE_ONLY" = "1" ]; then
    if [ -z "$LATEST_TAG" ] || ! install_release; then
        echo "==> FATAL: Unable to verify the latest salviumd release." >&2
        exit 1
    fi
    exit 0
fi

mkdir -p "$(dirname "$BINARY")"

LOCAL_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    LOCAL_VERSION=$(cat "$VERSION_FILE")
fi

if [ ! -x "$BINARY" ]; then
    echo "==> No binary found. A verified download is required."
    if [ -z "$LATEST_TAG" ]; then
        echo "==> Release API unavailable. Retrying once..."
        fetch_release
    fi
    if [ -z "$LATEST_TAG" ] || ! install_release; then
        echo "==> FATAL: Unable to install a verified salviumd binary." >&2
        exit 1
    fi
elif [ -z "$LATEST_TAG" ]; then
    echo "==> Could not reach GitHub API; using existing binary."
elif [ "$LATEST_TAG" != "$LOCAL_VERSION" ]; then
    echo "==> New version detected: ${LATEST_TAG} (current: ${LOCAL_VERSION:-none})."
    if ! install_release; then
        echo "==> FATAL: Update failed and no usable fallback remained." >&2
        exit 1
    fi
else
    echo "==> Binary is up to date (${LOCAL_VERSION})."
fi

echo "==> Starting salviumd..."
exec "$BINARY" --non-interactive "$@"

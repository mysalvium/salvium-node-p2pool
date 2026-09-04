#!/bin/bash
set -eu
umask 022

# GitLab project: whiskyrelaxing-group/p2pool-salvium-releases
PROJECT_ID="whiskyrelaxing-group%2Fp2pool-salvium-releases"
RELEASES_API="https://gitlab.com/api/v4/projects/${PROJECT_ID}/releases"
BINARY="/home/p2pool/.p2pool/bin/p2pool-salvium"
VERSION_FILE="/home/p2pool/.p2pool/bin/.current_version"
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
        LATEST_TAG=$(printf '%s' "$RELEASE_JSON" | jq -r '.[0].tag_name // empty' 2>/dev/null) || LATEST_TAG=""
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
    local release download_url checksum_url asset_name archive checksum_file extract_dir expected_sha actual_sha p2pool_bin
    release=$(printf '%s' "$RELEASE_JSON" | jq -c '.[0] // empty' 2>/dev/null) || release=""
    download_url=$(printf '%s' "$release" | jq -r \
        '.assets.links[]? | select(.name | test("Linux x64 \\(static"; "i")) | (.direct_asset_url // .url)' \
        2>/dev/null | head -n 1) || download_url=""
    checksum_url=$(printf '%s' "$release" | jq -r \
        '.assets.links[]? | select(.name | test("SHA256 Checksums"; "i")) | (.direct_asset_url // .url)' \
        2>/dev/null | head -n 1) || checksum_url=""

    if [ -z "$download_url" ] || [ -z "$checksum_url" ]; then
        fallback_or_fail "Release ${LATEST_TAG} is missing its Linux x64 asset or SHA-256 manifest."
        return $?
    fi

    asset_name=${download_url##*/}
    asset_name=${asset_name%%\?*}
    if [ -z "$asset_name" ]; then
        fallback_or_fail "Could not determine the P2Pool asset filename."
        return $?
    fi

    TMPDIR=$(mktemp -d)
    archive="${TMPDIR}/${asset_name}"
    checksum_file="${TMPDIR}/sha256sums.txt"
    extract_dir="${TMPDIR}/extract"
    mkdir -p "$extract_dir"

    echo "==> Downloading ${asset_name} and its checksum manifest..."
    if ! curl -fSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --max-time 120 -o "$archive" "$download_url"; then
        fallback_or_fail "Download failed for ${asset_name}."
        return $?
    fi
    if ! curl -fSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --max-time 30 -o "$checksum_file" "$checksum_url"; then
        fallback_or_fail "Checksum-manifest download failed for ${asset_name}."
        return $?
    fi

    expected_sha=$(awk -v file="$asset_name" \
        '$2 == file && length($1) == 64 && $1 !~ /[^A-Fa-f0-9]/ { print tolower($1); exit }' \
        "$checksum_file")
    if [ ${#expected_sha} -ne 64 ]; then
        fallback_or_fail "The checksum manifest has no valid entry for ${asset_name}."
        return $?
    fi

    actual_sha=$(sha256sum "$archive" | awk '{print tolower($1)}')
    if [ "$actual_sha" != "$expected_sha" ]; then
        fallback_or_fail "SHA-256 mismatch for ${asset_name}; expected ${expected_sha}, received ${actual_sha}."
        return $?
    fi
    echo "==> SHA-256 verified: ${actual_sha}"

    if ! tar xzf "$archive" --no-same-owner --no-same-permissions -C "$extract_dir"; then
        fallback_or_fail "Verified archive could not be extracted."
        return $?
    fi
    p2pool_bin=$(find "$extract_dir" -type f -name 'p2pool*' ! -name '*.txt' ! -name '*.md' | head -n 1)
    if [ -z "$p2pool_bin" ]; then
        fallback_or_fail "Verified archive did not contain a P2Pool binary."
        return $?
    fi

    if [ "$VERIFY_RELEASE_ONLY" = "1" ]; then
        cleanup
        TMPDIR=""
        echo "==> Release ${LATEST_TAG} passed checksum, archive, and binary-content verification."
        return 0
    fi

    if ! atomic_install "$p2pool_bin"; then
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

echo "==> Checking for p2pool-salvium updates..."
fetch_release

if [ "$VERIFY_RELEASE_ONLY" = "1" ]; then
    if [ -z "$LATEST_TAG" ] || ! install_release; then
        echo "==> FATAL: Unable to verify the latest P2Pool release." >&2
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
        echo "==> FATAL: Unable to install a verified P2Pool binary." >&2
        exit 1
    fi
elif [ -z "$LATEST_TAG" ]; then
    echo "==> Could not reach GitLab API; using existing binary."
elif [ "$LATEST_TAG" != "$LOCAL_VERSION" ]; then
    echo "==> New version detected: ${LATEST_TAG} (current: ${LOCAL_VERSION:-none})."
    if ! install_release; then
        echo "==> FATAL: Update failed and no usable fallback remained." >&2
        exit 1
    fi
else
    echo "==> Binary is up to date (${LOCAL_VERSION})."
fi

echo "==> Starting p2pool-salvium..."
exec "$BINARY" "$@"

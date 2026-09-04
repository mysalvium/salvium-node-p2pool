#!/usr/bin/env bash
# Verify the newest compressed backup and restore selected non-secret state
# into a root-only temporary directory. Production files are never modified.
set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

SELF_PATH=$(readlink -f -- "$0")
HOST_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)
CONFIG_FILE="$HOST_DIR/operations.conf"

die() { printf 'verify-salvium-backup: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || die "run as root"
[[ -f "$SELF_PATH" && ! -L "$SELF_PATH" && $(stat -c %u -- "$SELF_PATH") = 0 ]] || die "script must be a root-owned regular file"
[[ -d "$HOST_DIR" && ! -L "$HOST_DIR" && $(stat -c %u -- "$HOST_DIR") = 0 ]] || die "host directory must be root-owned"
(( (8#$(stat -c %a -- "$SELF_PATH") & 022) == 0 )) || die "script is writable by group/other"
(( (8#$(stat -c %a -- "$HOST_DIR") & 022) == 0 )) || die "host directory is writable by group/other"
[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || die "operations.conf is missing or unsafe"
[[ $(stat -c %u -- "$CONFIG_FILE") = 0 ]] || die "operations.conf must be root-owned"
(( (8#$(stat -c %a -- "$CONFIG_FILE") & 022) == 0 )) || die "operations.conf is writable by group/other"

config_value() { sed -n "s/^${1}=//p" "$CONFIG_FILE" | tail -n 1; }
BACKUP_DIR=$(config_value BACKUP_DIR)
MAX_BACKUP_AGE=$(config_value MAX_BACKUP_AGE)
[[ "$BACKUP_DIR" =~ ^/[A-Za-z0-9._/-]+$ && -d "$BACKUP_DIR" ]] || die "invalid BACKUP_DIR"
[[ "$MAX_BACKUP_AGE" =~ ^[0-9]+$ ]] || die "invalid MAX_BACKUP_AGE"

exec 9>"$HOST_DIR/backup-verify.lock"
flock -n 9 || exit 0

archive=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'salvium-full-*.tar.zst' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)
[[ -n "$archive" && -f "$archive" && ! -L "$archive" ]] || die "no safe backup archive found"
resolved=$(readlink -f -- "$archive")
[[ "$resolved" == "$BACKUP_DIR"/salvium-full-*.tar.zst ]] || die "backup path escaped BACKUP_DIR"
[[ -f "${archive}.sha256" && ! -L "${archive}.sha256" ]] || die "backup checksum is missing or unsafe"

age=$(( $(date +%s) - $(stat -c %Y -- "$archive") ))
(( age <= MAX_BACKUP_AGE )) || die "latest backup is older than policy allows"

sha256sum -c -- "${archive}.sha256" >/dev/null
zstd --test --quiet "$archive"

restore_root=$(mktemp -d "$HOST_DIR/restore-test.XXXXXX")
cleanup() { rm -rf -- "$restore_root"; }
trap cleanup EXIT INT TERM

members=(
    salvium/data/p2pool-control/active
    salvium/data/p2pool/bin/.current_version
    salvium/data/salviumd-bin/.current_version
)
tar -I zstd -xpf "$archive" --no-same-owner --no-same-permissions -C "$restore_root" "${members[@]}"

mode=$(tr -d '[:space:]' < "$restore_root/${members[0]}")
[[ "$mode" = public || "$mode" = private || "$mode" = auto ]] || die "restored mode state is invalid"
for version_file in "$restore_root/${members[1]}" "$restore_root/${members[2]}"; do
    version=$(tr -d '[:space:]' < "$version_file")
    [[ "$version" =~ ^v?[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "restored version marker is invalid"
done

printf 'PASS: newest backup checksum, compressed stream, and selected-file restore test\n'

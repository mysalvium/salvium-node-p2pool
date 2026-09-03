#!/bin/bash
set -Eeuo pipefail

readonly SOURCE_DATASET="${SOURCE_DATASET:-sharedrive/apps}"
readonly SOURCE_NAME="${SOURCE_NAME:-salvium}"
readonly SOURCE_MOUNT_ROOT="${SOURCE_MOUNT_ROOT:-/mnt/sharedrive/apps}"
readonly BACKUP_DIR="${BACKUP_DIR:-/mnt/sharedrive/backups/salvium-node}"
readonly RETENTION_COUNT="${RETENTION_COUNT:-8}"
readonly SNAPSHOT_PREFIX="${SNAPSHOT_PREFIX:-salvium-weekly-}"
readonly RPC_URL="${RPC_URL:-http://127.0.0.1:19081/save_bc}"
readonly RPC_PAYLOAD='{}'

umask 077
mkdir -p "${BACKUP_DIR}"
exec 9>"/run/lock/salvium-weekly-backup.lock"
if ! flock -n 9; then
  printf '%s Another Salvium backup is already running; exiting.\n' "$(date --iso-8601=seconds)" >> "${BACKUP_DIR}/backup.log"
  exit 0
fi

exec >> "${BACKUP_DIR}/backup.log" 2>&1

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot_name="${SNAPSHOT_PREFIX}${timestamp}"
snapshot="${SOURCE_DATASET}@${snapshot_name}"
snapshot_root="${SOURCE_MOUNT_ROOT}/.zfs/snapshot/${snapshot_name}"
archive="${BACKUP_DIR}/salvium-full-${timestamp}.tar.zst"
partial="${archive}.partial"
metadata="${BACKUP_DIR}/salvium-full-${timestamp}.metadata.txt"
rpc_response="$(mktemp -p "${BACKUP_DIR}" .save-bc.XXXXXX)"
snapshot_created=0

cleanup() {
  local exit_code=$?
  rm -f -- "${partial}" "${rpc_response}"
  if [[ "${snapshot_created}" -eq 1 ]] && zfs list -H -t snapshot -o name "${snapshot}" >/dev/null 2>&1; then
    zfs destroy "${snapshot}" || true
  fi
  if [[ "${exit_code}" -ne 0 ]]; then
    printf '%s Backup FAILED (exit %d).\n' "$(date --iso-8601=seconds)" "${exit_code}"
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

printf '\n%s Starting Salvium full backup.\n' "$(date --iso-8601=seconds)"

if [[ "$(docker inspect -f '{{.State.Running}}' salviumd 2>/dev/null || true)" != "true" ]]; then
  printf 'salviumd is not running; refusing to create an unverified live backup.\n' >&2
  exit 1
fi

# Ask the daemon to commit its blockchain state before the atomic ZFS snapshot.
curl --fail --silent --show-error --max-time 120 \
  -H 'Content-Type: application/json' \
  --data "${RPC_PAYLOAD}" \
  "${RPC_URL}" > "${rpc_response}"
if grep -q '"error"' "${rpc_response}"; then
  printf 'save_bc RPC returned an error: ' >&2
  sed -E 's/[[:space:]]+/ /g' "${rpc_response}" >&2
  printf '\n' >&2
  exit 1
fi
printf '%s Blockchain flush completed.\n' "$(date --iso-8601=seconds)"

zfs snapshot "${snapshot}"
snapshot_created=1

if [[ ! -d "${snapshot_root}/${SOURCE_NAME}" ]]; then
  printf 'Snapshot source is not accessible at %s.\n' "${snapshot_root}/${SOURCE_NAME}" >&2
  exit 1
fi

{
  printf 'backup_format=salvium-full-v1\n'
  printf 'created_utc=%s\n' "${timestamp}"
  printf 'host=%s\n' "$(hostname)"
  printf 'source_dataset=%s\n' "${SOURCE_DATASET}"
  printf 'source_path=%s/%s\n' "${SOURCE_MOUNT_ROOT}" "${SOURCE_NAME}"
  printf 'snapshot=%s\n' "${snapshot}"
  printf 'salviumd_image=%s\n' "$(docker inspect -f '{{.Config.Image}}' salviumd)"
  printf 'salviumd_version=%s\n' "$(docker exec salviumd salviumd --version 2>/dev/null | head -n 1)"
} > "${metadata}"

printf '%s Compressing snapshot into %s.\n' "$(date --iso-8601=seconds)" "${archive}"
if command -v ionice >/dev/null 2>&1; then
  ionice -c 2 -n 7 nice -n 10 tar -I 'zstd -T0 -6' -cpf "${partial}" -C "${snapshot_root}" "${SOURCE_NAME}"
else
  nice -n 10 tar -I 'zstd -T0 -6' -cpf "${partial}" -C "${snapshot_root}" "${SOURCE_NAME}"
fi

mv -- "${partial}" "${archive}"
sha256sum "${archive}" > "${archive}.sha256"
zstd --test --quiet "${archive}"
tar -I zstd -tf "${archive}" >/dev/null
printf '%s Archive integrity verified.\n' "$(date --iso-8601=seconds)"

mapfile -t archives < <(find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'salvium-full-*.tar.zst' -printf '%f\n' | sort -r)
for ((i=RETENTION_COUNT; i<${#archives[@]}; i++)); do
  old_archive="${BACKUP_DIR}/${archives[$i]}"
  old_stem="${old_archive%.tar.zst}"
  rm -f -- "${old_archive}" "${old_archive}.sha256" "${old_stem}.metadata.txt"
  printf '%s Pruned expired backup %s.\n' "$(date --iso-8601=seconds)" "$(basename "${old_archive}")"
done

archive_size="$(du -h "${archive}" | awk '{print $1}')"
printf '%s Backup complete: %s (%s), retaining %d weekly archives.\n' \
  "$(date --iso-8601=seconds)" "${archive}" "${archive_size}" "${RETENTION_COUNT}"

# TrueNAS health, backup, and recovery checks

These operations are intended for TrueNAS SCALE with the ZFS paths configured
in `.env`. They install root-owned copies outside the Git working tree, then
schedule those protected copies through TrueNAS.

## Install or refresh

Run as root from the repository directory after the live stack is healthy:

```sh
./scripts/install-truenas-operations.sh install .env
./scripts/install-truenas-operations.sh check .env
```

The installer creates or updates exactly one of each job:

| Job | Schedule | Purpose |
| --- | --- | --- |
| Salvium live health monitor | Every 5 minutes | Detect unhealthy/drifted services and stale state |
| Salvium weekly compressed backup | Sunday 03:15 | Flush, snapshot, archive, checksum, and retain eight backups |
| Salvium weekly restore verification | Sunday 05:00 | Verify and test selected-file extraction without touching production |

Running the installer again refreshes the protected script copies,
configuration, and the same Cron Jobs. It does not create duplicates.

## What the health monitor checks

- Expected container image tags and running/healthy state
- P2Pool and dashboard non-root/read-only/capability boundaries
- Restricted RPC availability and node synchronization
- Dashboard availability and fresh P2Pool statistics
- The dedicated Salvium firewall chains
- Fresh restricted Docker-broker status
- Backup age and presence of its checksum
- Byte-for-byte equality between the repository Compose file and Portainer's
  deployed Compose file

The monitor records root-only state and a short log and returns a nonzero exit
status on failure. Check it manually with:

```sh
./scripts/install-truenas-operations.sh check .env
```

## Backup verification

Run the non-destructive test at any time:

```sh
./scripts/install-truenas-operations.sh verify-backup .env
```

It verifies the newest archive checksum, tests the Zstandard stream, and
extracts the active P2Pool mode plus two version markers into a temporary
root-only directory. The temporary directory is deleted when the test ends.
It does not overwrite live data and is not a complete disaster-recovery drill.

If verification fails, do not delete or overwrite the suspect archive. Create
a fresh backup, verify the new archive independently, and inspect ZFS pool and
disk health. A previously valid archive becoming unreadable is a storage-health
signal even when the live containers remain healthy.

## Recovery principles

1. Stop and identify whether the failure is configuration, image, binary, or
   persistent data. Do not replace good data while diagnosing a container.
2. Keep the protected pre-change bundle and the previous binary retained by
   the updater. Compose/image rollback normally does not require restoring the
   blockchain.
3. Verify an archive before a full restore. A full restore is destructive and
   intentionally is not automated by this repository.
4. Stop the stack before replacing persistent data, restore into a new path
   when possible, validate ownership, then point Compose at the recovered path.
5. Start the node first, confirm synchronization, then P2Pool, the dashboard,
   management services, firewall, and finally the automated health check.

The backup job removes only its temporary ZFS snapshot and archives older than
the retention count. Review `SALVIUM_BACKUP_DIR`, available space, and the ZFS
dataset paths before adapting it to another server.

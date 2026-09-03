# Architecture

The stack uses Docker Compose's default bridge network. P2Pool connects to the
daemon's restricted RPC port and ZMQ endpoint by service name. The statistics
service reads P2Pool's generated API files through a read-only bind mount.

Persistent data lives below `SALVIUM_DATA_ROOT`. Operational scripts are read
from `SALVIUM_APP_ROOT/ops`. No named Docker volumes are used.

The updater containers periodically compare local version marker files with
the latest upstream release. A version change causes the target container to
restart; its entrypoint then downloads the new binary into the persistent
binary directory. The watchdog reads P2Pool statistics and control state and
can restart P2Pool when switching between public and private modes.

The Compose file retains the production resource limits and hardening:

- Salvium daemon: two CPUs, 4192 MiB, read-only root, capabilities dropped,
  `no-new-privileges`, and a two-minute stop grace period.
- P2Pool: two CPUs, 4192 MiB, unlimited memlock, hugepages, `IPC_LOCK`, and
  `SYS_ADMIN`.
- JSON-file logs rotate at three 10 MiB files per service.

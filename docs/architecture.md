# Architecture

The stack uses four purpose-specific Docker bridge networks. P2Pool and the
daemon share `salvium_node`; P2Pool connects to restricted RPC and ZMQ by
service name. The internal `salvium_privileged_rpc` network has no Internet
gateway and carries unrestricted RPC only for explicitly attached server-side
wallet services. Statistics and management services do not share either node
network.

The statistics service reads P2Pool's generated API files through a read-only
bind mount. Published LAN services are protected by explicit host-address
bindings and narrow Docker-forwarding/host-ingress policies managed by
`salvium-firewall`. See
[`ports-and-networks.md`](ports-and-networks.md).

Persistent data lives below `SALVIUM_DATA_ROOT`. Operational scripts are read
from `SALVIUM_APP_ROOT/ops`. No named Docker volumes are used.

The updater containers periodically compare local version marker files with
the latest upstream release. The watchdog reads P2Pool statistics and control
state. None of those three containers has Docker-socket access. They submit
fixed restart requests through separate bind-mounted directories.

A root-owned host broker scheduled by TrueNAS once per minute maps each
directory to an allowlisted target, coalesces duplicate P2Pool requests,
enforces a five-minute per-target rate limit, and performs the restart. It also
publishes a read-only P2Pool state snapshot for the watchdog. The broker is
installed outside the Git working tree and is not mounted by any container.
See [`docker-control-broker.md`](docker-control-broker.md) and
[`automatic-downloads.md`](automatic-downloads.md).

The Compose file retains the production resource limits and hardening:

- Salvium daemon: two CPUs, 4192 MiB, read-only root, capabilities dropped,
  `no-new-privileges`, and a two-minute stop grace period.
- P2Pool: two CPUs, 4192 MiB, unlimited memlock, hugepages, `IPC_LOCK`, and
  `SYS_ADMIN`.
- Firewall: read-only root, only `NET_ADMIN`, host networking, no Docker socket,
  no host filesystem mount, and no listening service.
- Updaters and watchdog: non-root, read-only root filesystems, all capabilities
  dropped, `no-new-privileges`, and no Docker socket.
- JSON-file logs rotate at three 10 MiB files per service.

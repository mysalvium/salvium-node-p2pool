# Security and reproducibility notes

Implemented download protections:

- Salvium release archives are verified against the SHA-256 checksum in the
  official GitHub release notes.
- P2Pool release archives are verified against the SHA-256 manifest attached
  to the corresponding GitLab release.
- Missing or mismatched checksums fail closed: an update is rejected before
  extraction or installation.
- Installation uses a temporary file and an atomic rename in the persistent
  binary directory. The replaced executable is retained with a `.previous`
  suffix as a rollback copy.
- Downloads and redirects are restricted to HTTPS with TLS 1.2 or newer.
- A non-installing end-to-end verification mode exercises the same production
  download and checksum path against the current real releases.

The checksum and archive currently come from the same release channel. This
protects against corruption and mismatched downloads, but an independently
verified digital signature would provide stronger publisher authentication.

Implemented supply-chain protections:

- All Ubuntu, Alpine, and Python base references are pinned to immutable
  multi-platform manifest digests. Alpine uses a supported release branch.
- The statistics application source is pinned to a reviewed full commit.
- Python runtime dependencies are exact-version locked and every downloaded
  wheel must match an expected SHA-256 hash.
- The scanner release archive is pinned and checksum-verified before use. It
  checks repository secrets, Compose/Dockerfile configuration, dependencies,
  and all five images; it fails on fixable critical image vulnerabilities and
  emits SPDX JSON SBOMs.
- GitHub runs the checks on pushes, pull requests, weekly, and on demand.
  Third-party Actions are pinned to full commit SHAs. Dependabot proposes
  reviewed updates for Docker bases, Python dependencies, and Actions.

See [`supply-chain.md`](supply-chain.md) for the update procedure and limits.

Implemented Docker-control protections:

- No container mounts `/var/run/docker.sock`.
- The updater and watchdog containers run non-root with read-only root
  filesystems, all capabilities dropped, and `no-new-privileges`.
- Each controller can write only to its dedicated request directory. It cannot
  choose a container name or provide a command.
- A root-owned host broker maps requests to the fixed `salviumd` or
  `salvium-p2pool` target, coalesces duplicate requests, rate-limits restarts,
  and rejects symlinks, unexpected owners, oversized files, and malformed
  identifiers.
- The root-executed broker copy and configuration live in a root-only data
  directory that is not mounted into any container. TrueNAS schedules that
  installed copy rather than the Git working-tree source.

This boundary limits a compromised controller to requesting a rate-limited
restart of its assigned service. The broker itself remains trusted root code
and must retain root-only ownership. See
[`docker-control-broker.md`](docker-control-broker.md).

Implemented network protections:

- Unrestricted RPC `19081` is not published on the host.
- Privileged RPC uses a no-egress Docker network shared only with explicitly
  authorized wallet services.
- Restricted RPC, Stratum, statistics, and private P2Pool traffic use explicit
  host bindings and source-CIDR rules for both forwarded Docker traffic and
  same-host Docker bridge traffic.
- P2Pool's Stratum/HTTP listener is bound to the LAN address and protected by
  source-CIDR rules. It is not exposed to the internet or unrelated Docker
  networks.
- The statistics application is pinned to a reviewed commit and no longer runs
  `git pull` when the container starts.
- Node, statistics, updater, and watchdog containers use separate networks.

Implemented runtime privilege protections:

- P2Pool runs non-root with a read-only root filesystem, all capabilities
  dropped except `IPC_LOCK`, and `no-new-privileges`. `SYS_ADMIN` is not used.
- The statistics dashboard runs non-root under Gunicorn, uses an unprivileged
  internal port, has a read-only root filesystem, and has no capabilities.
- Every long-running service has a process-count limit in addition to the
  service-specific CPU and memory limits.

The firewall container necessarily has `NET_ADMIN` in the host network
namespace. It is deliberately small, read-only, has no Docker socket or host
mounts, and serves no port. See [`ports-and-networks.md`](ports-and-networks.md)
for the rule model and rollback command.

The original production payout address and RPC health-check credential are not
present in this repository. The health check uses restricted RPC without
authentication. Automated backup verification restores only selected
non-secret files into a temporary root-only directory; it never overwrites live
data. See [`operations-and-recovery.md`](operations-and-recovery.md).

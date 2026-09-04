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

Before production use:

- Pin base images and `docker:cli` by version or digest.
- Determine whether P2Pool can run without `SYS_ADMIN`.
- Consider replacing Docker-socket access with a narrower update mechanism.
- Run a secret scanner before every release and before adding any Git remote.

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

The firewall container necessarily has `NET_ADMIN` in the host network
namespace. It is deliberately small, read-only, has no Docker socket or host
mounts, and serves no port. See [`ports-and-networks.md`](ports-and-networks.md)
for the rule model and rollback command.

The original production payout address and RPC health-check credential are not
present in this repository. The health check uses restricted RPC without
authentication.

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

The checksum and archive currently come from the same release channel. This
protects against corruption and mismatched downloads, but an independently
verified digital signature would provide stronger publisher authentication.

Before production use:

- Pin base images and `docker:cli` by version or digest.
- Pin the statistics application to a reviewed commit instead of pulling a
  moving branch at container startup.
- Determine whether P2Pool can run without `SYS_ADMIN`.
- Restrict RPC, Stratum, statistics, and P2Pool ports with host firewall rules
  or explicit bind addresses.
- Consider replacing Docker-socket access with a narrower update mechanism.
- Run a secret scanner before every release and before adding any Git remote.

The original production payout address and RPC health-check credential are not
present in this repository. The health check uses restricted RPC without
authentication.

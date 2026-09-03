# Security and reproducibility notes

Before production use:

- Pin base images and `docker:cli` by version or digest.
- Pin the statistics application to a reviewed commit instead of pulling a
  moving branch at container startup.
- Verify downloaded Salvium and P2Pool release artifacts by checksum or
  signature before installation.
- Determine whether P2Pool can run without `SYS_ADMIN`.
- Restrict RPC, Stratum, statistics, and P2Pool ports with host firewall rules
  or explicit bind addresses.
- Consider replacing Docker-socket access with a narrower update mechanism.
- Run a secret scanner before every release and before adding any Git remote.

The original production payout address and RPC health-check credential are not
present in this repository. The health check uses restricted RPC without
authentication.

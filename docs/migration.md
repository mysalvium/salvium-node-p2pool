# Migration from the existing Portainer stack

Do not redeploy the production stack directly from this repository without a
controlled maintenance window.

The inspected production environment has three important drift conditions:

1. Portainer's deployed Compose file differs from both host-side Compose files.
2. The live `salviumd` container does not have Compose ownership labels.
3. Runtime binaries are newer than the tags on their locally built images.

Recommended sequence:

1. Take and verify a backup of the existing data and binary directories.
2. Record the running binary versions, image IDs, ports, and container state.
3. Clone this repository to a new host directory; keep the existing data path.
4. Create `.env` locally and confirm the payout wallet and path values.
5. Run `docker compose config` and a secret scan.
6. Install the root-owned Docker broker and verify its TrueNAS Cron Job.
7. Build the five local images without stopping production.
8. Test against disposable data and non-production host ports.
9. Resolve ownership of the existing unlabeled `salviumd` container before
   allowing Compose to create a container with the same name.
10. Cut over during a maintenance window with a tested rollback procedure.
11. Confirm that no container mounts the Docker socket and that broker status
    remains fresh before enabling automatic failover.
12. Convert Portainer to a Git-backed stack only after the local deployment is
    proven and repository access is configured.

The production cutover must also coordinate the dependent services:

- Attach the two staker wallet-RPC containers to the external
  `salvium_privileged_rpc` network and change their daemon address to
  `salviumd:19081` before removing their ordinary egress network.
- Change the Hummingbot view-only wallet RPC from host port `19081` to
  restricted host port `19089`; it does not require privileged daemon methods.
- Confirm those three clients are healthy before declaring the unrestricted
  host-port removal successful.
- Run `scripts/verify-release-downloads.sh` before the cutover and retain both
  persistent `.previous` binaries.

See [`ports-and-networks.md`](ports-and-networks.md) for the final topology and
[`automatic-downloads.md`](automatic-downloads.md) for release verification.

The legacy migration scripts from the server are intentionally omitted because
they stop containers and mutate production directories.

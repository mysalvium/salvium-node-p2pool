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
6. Build the three local images without stopping production.
7. Test against disposable data and non-production host ports.
8. Resolve ownership of the existing unlabeled `salviumd` container before
   allowing Compose to create a container with the same name.
9. Cut over during a maintenance window with a tested rollback procedure.
10. Convert Portainer to a Git-backed stack only after the local deployment is
    proven and repository access is configured.

The legacy migration scripts from the server are intentionally omitted because
they stop containers and mutate production directories.

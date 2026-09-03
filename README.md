# Salvium Node and P2Pool Stack

Docker Compose configuration for a Salvium pruned node, dual-mode P2Pool,
statistics UI, release updaters, and the P2Pool watchdog.

This repository was derived from the production TrueNAS/Portainer stack. It
contains source and configuration templates only. Wallets, blockchain data,
downloaded binaries, logs, credentials, and Portainer tokens are intentionally
excluded.

## Services

- `salviumd`: pruned Salvium daemon
- `p2pool`: public/private P2Pool with Stratum
- `stats`: P2Pool statistics UI
- `perms`: one-time runtime-directory ownership initialization
- `salviumd-updater` and `p2pool-updater`: release checks and restarts
- `p2pool-watchdog`: health monitoring and public/private mode switching

## Configure

1. Copy `.env.example` to `.env`.
2. Set `SALVIUM_APP_ROOT` to the directory containing this repository on the
   Docker host.
3. Set `SALVIUM_DATA_ROOT` to a persistent data directory outside Git.
4. Replace `P2POOL_WALLET` with the public payout address.
5. Review every published port before deployment.

For private-sidechain mode, copy `config/sidechain.example.json` to
`${SALVIUM_DATA_ROOT}/p2pool/sidechain.json` and confirm the parameters are
correct for the intended sidechain.

## Build and validate

```bash
./scripts/build-images.sh
docker compose --env-file .env config
```

Do not point an untested checkout at production data. Read
`docs/migration.md` before replacing an existing Portainer stack.

## Security notes

- `.env` is ignored and must never be committed.
- The daemon health check uses the local restricted RPC endpoint and requires
  no embedded RPC credential.
- The updater and watchdog services mount the Docker socket and therefore have
  host-level control through Docker.
- P2Pool currently receives `SYS_ADMIN` and `IPC_LOCK`; reassess whether both
  remain necessary.
- Release downloads and floating image tags should be pinned and verified
  before treating builds as reproducible.

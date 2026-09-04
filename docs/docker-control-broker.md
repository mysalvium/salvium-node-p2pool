# Restricted Docker control broker

Docker's local socket normally provides all-or-nothing control over the Docker
daemon. A container that can write to `/var/run/docker.sock` can usually create
a privileged container, mount host files, read other container configuration,
or disrupt unrelated services. Mounting the socket read-only does not make the
Docker API read-only.

This stack therefore does not mount the Docker socket into any container.

## How automatic control works

The three unprivileged management containers retain their original jobs:

| Requester | What it decides | Only permitted target |
| --- | --- | --- |
| `salviumd-updater` | A newer Salvium release is available | `salviumd` |
| `p2pool-updater` | A newer P2Pool release is available | `salvium-p2pool` |
| `p2pool-watchdog` | Failover or remedial restart is required | `salvium-p2pool` |

Each requester can write only to its own directory below
`SALVIUM_DATA_ROOT/docker-control/requests`. A request contains an opaque
identifier, not a command or container name.

TrueNAS runs an installed broker copy as root once per minute. The broker:

1. Claims request files into a root-only directory before reading them.
2. Rejects symlinks, non-regular files, unexpected owners, multiple hard
   links, files larger than 128 bytes, and malformed identifiers.
3. Maps the request directory to a hardcoded container target.
4. Coalesces simultaneous updater/watchdog requests for P2Pool into one
   restart.
5. Allows no more than one restart attempt per target every five minutes.
6. Uses an absolute Docker executable path and a bounded stop timeout.
7. Writes a result for the requester and a validated P2Pool state snapshot.

The broker has no network listener. Its source template is in `ops`, but the
installer copies it to a root-owned `0700` directory outside the repository.
No container mounts that host directory or the root-owned status directory
writable.

## Install on TrueNAS SCALE

Run from the repository directory as root:

```sh
./scripts/install-truenas-docker-broker.sh install .env
```

The installer reads only `SALVIUM_DATA_ROOT`, `PUID`, and `PGID` from `.env`;
it does not source or execute the file. It creates or updates one TrueNAS Cron
Job named `Salvium restricted Docker controller`. Re-running the installer is
safe and updates the installed broker copy.

After the Compose stack is running, verify the entire boundary:

```sh
./scripts/install-truenas-docker-broker.sh check .env
```

The check confirms the installed broker and Cron Job, live P2Pool status, and
that all three management containers are non-root, read-only, capability-free,
protected by `no-new-privileges`, and have no Docker socket.

View the broker's audit trail:

```sh
tail -n 100 "$SALVIUM_DATA_ROOT/docker-control/host/broker.log"
```

The log is root-only and automatically trims itself after reaching 1 MiB.

## Other Linux Docker hosts

The supplied task installer uses the TrueNAS middleware API. On another Linux
host, copy `ops/salvium-docker-broker.sh` and a matching `broker.conf` into a
root-owned, non-container-mounted directory with the same sibling `requests`
and `status` layout. Schedule
`/usr/bin/bash /path/to/the/installed/broker run` once per minute using the
host's root task scheduler. Never schedule the copy in the
Git working tree or any directory writable by a container or unprivileged
account.

## Failure behavior

- Docker restart policies still recover ordinary container crashes.
- If the Cron Job stops, the updater and watchdog containers cannot perform
  requested restarts. They time out and log an error rather than gaining more
  authority.
- The watchdog treats broker status older than three minutes as unknown.
- A compromised requester can cause denial of service by requesting its
  allowlisted restart repeatedly, but the five-minute host rate limit bounds
  that behavior. It cannot select another target or execute a host command.

## Rollback

Before changing the live stack, retain the previous Portainer Compose file and
the TrueNAS system configuration. If the broker fails, keep the node and
P2Pool containers running and perform required restarts manually from the
TrueNAS host while correcting the task. Reintroducing the raw Docker socket
mount restores automation but also restores root-equivalent container access,
so it should be an emergency-only rollback.

Disable or edit the broker task through **System Settings → Advanced → Cron
Jobs**. Do not delete the root-owned broker directory until no request-based
management container depends on it.

Primary references:

- [Docker Engine security](https://docs.docker.com/engine/security/)
- [Docker authorization plugins](https://docs.docker.com/engine/extend/plugins_authorization/)
- [TrueNAS Cron Jobs](https://www.truenas.com/docs/scale/systemsettings/advanced/managecronjobs/)

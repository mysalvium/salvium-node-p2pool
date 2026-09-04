# Salvium Node and P2Pool Stack

An easy-to-run Docker stack for hosting a Salvium node and mining through
P2Pool. It was built from a working TrueNAS/Portainer installation and is
designed to keep mining with as little manual intervention as possible.

You do not need to be a Docker expert. The setup section explains what to
change, what to leave alone, and which commands to copy and paste.

## What is special about this stack?

### Automatic Salvium and P2Pool updates

The stack checks upstream releases every six hours by default:

- `salviumd-updater` checks the official Salvium GitHub releases.
- `p2pool-updater` checks the P2Pool Salvium GitLab releases.
- When a newer release is found, the updater restarts only the affected
  container.
- During that restart, the container downloads the new binary and records its
  version in the persistent data directory.
- If the release service cannot be reached, the existing binary continues to
  be used.

This keeps the software current without rebuilding the whole stack. An update
causes a brief restart of the affected service.

### Automatic public-to-private mining failover

P2Pool normally mines on the public sidechain. In `auto` mode, the watchdog
can move mining to the configured private sidechain when public mining stops
working correctly.

It watches for:

- A stopped or repeatedly crashing P2Pool container
- Mining statistics that have stopped updating
- A public-sidechain peer count of zero
- A public-sidechain height that has stopped advancing

With the default settings, public mining must remain unhealthy for 15 minutes
before the watchdog falls back to private mode. Short network interruptions do
not immediately trigger a switch.

While mining privately, the watchdog keeps probing known public peers. After
public peers have remained reachable for 30 minutes, it performs a five-minute
trial return. Public mode must advance the sidechain height at least twice or
the stack returns to private mining. Repeated failed trials use progressively
longer recovery waits to prevent constant switching.

The Stratum address and port do not change during a switch. Connected mining
devices continue using the same address and normally do not need to be
reconfigured.

Automatic switching is opt-in. After configuring private mode and starting the
stack, run:

```bash
./ops/salvium-mode auto
```

### Safe switching and restart-resistant state

- A one-hour minimum dwell time prevents rapid back-and-forth switching.
- Watchdog timers are stored in `state.json`, so restarting the watchdog does
  not erase an outage or bypass the anti-flapping timer.
- Every switch is recorded in `switch.log`.
- If a private P2Pool instance becomes unhealthy, it is restarted in private
  mode rather than switching to a broken public sidechain.
- Public and private P2Pool data are stored separately.

### Built-in statistics page

The `stats` service provides a web interface for P2Pool statistics. By default,
open this address in a browser after the stack starts:

```text
http://YOUR-SERVER-IP:3000
```

### Production-minded defaults

- The Salvium daemon runs with a read-only container filesystem.
- Linux capabilities are removed from the daemon.
- `no-new-privileges` is enabled for the daemon.
- Container logs rotate automatically instead of growing forever.
- The daemon is given two minutes to shut down cleanly.
- A TrueNAS/ZFS backup helper is included in `ops/backup-salvium.sh`.
- Wallets, blockchain data, logs, credentials, and local configuration are
  excluded from Git.

## What runs in the stack?

| Service | What it does |
| --- | --- |
| `salviumd` | Runs a pruned Salvium node |
| `p2pool` | Provides public/private P2Pool and the Stratum mining port |
| `stats` | Serves the P2Pool statistics web page |
| `perms` | Creates runtime directories and fixes their ownership |
| `salviumd-updater` | Checks for new Salvium daemon releases |
| `p2pool-updater` | Checks for new P2Pool Salvium releases |
| `p2pool-watchdog` | Monitors mining and controls public/private failover |

## Before you begin

You need:

1. A Linux-based Docker server, such as TrueNAS SCALE or a normal Linux server.
2. Docker with Docker Compose v2. Test it with:

   ```bash
   docker compose version
   ```

3. A public Salvium wallet address for receiving mining payouts.
4. Enough storage for the blockchain and P2Pool data. The inspected pruned
   production chain used about 5 GB, but it will grow, so allow considerably
   more free space.
5. At least about 9 GB of memory available if you keep the supplied 4192 MB
   limits for both the daemon and P2Pool.

Run the commands below in the shell of the Docker server—not in a wallet
console. Replace example paths with real paths on your server.

## Beginner setup

### Step 1: Download the repository

If you have access to this private repository, use HTTPS:

```bash
git clone https://github.com/mysalvium/salvium-node-p2pool.git
cd salvium-node-p2pool
```

If GitHub says the repository cannot be found, make sure you are signed in to
an account that has permission to access it.

You may also use GitHub's **Code → Download ZIP** button, extract the ZIP, and
open a terminal in the extracted directory.

### Step 2: Create your private settings file

Copy the example file:

```bash
cp .env.example .env
```

Open it in a simple editor:

```bash
nano .env
```

At minimum, change these three values:

```dotenv
SALVIUM_APP_ROOT=/full/path/to/salvium-node-p2pool
SALVIUM_DATA_ROOT=/full/path/to/salvium-data
P2POOL_WALLET=YOUR_PUBLIC_SALVIUM_WALLET_ADDRESS
```

What they mean:

- `SALVIUM_APP_ROOT` is this repository's full directory path. Run `pwd` from
  the repository directory if you are unsure.
- `SALVIUM_DATA_ROOT` is where blockchain, P2Pool, statistics, and downloaded
  binaries will be stored. Keep it outside the Git repository.
- `P2POOL_WALLET` is the public address that receives mining payouts. Never
  enter a wallet seed phrase, private key, or wallet password here.

In `nano`, press **Ctrl+O**, **Enter**, then **Ctrl+X** to save and exit.

The remaining values already match the production stack and can normally be
left unchanged for the first start.

### Step 3: Prepare private-sidechain mode

This step is required before enabling automatic failover.

Create the P2Pool data directory and copy the example sidechain definition:

```bash
mkdir -p "$(grep '^SALVIUM_DATA_ROOT=' .env | cut -d= -f2-)/p2pool"
cp config/sidechain.example.json "$(grep '^SALVIUM_DATA_ROOT=' .env | cut -d= -f2-)/p2pool/sidechain.json"
```

The included values match the private sidechain used by the original stack.
Confirm them with the operator of the private sidechain you intend to use.
Every miner on that private sidechain must use compatible settings.

If you only want public mining, you may skip this step and leave the watchdog
pinned to public mode.

### Step 4: Check the configuration

This command checks the Compose file without starting anything:

```bash
docker compose --env-file .env config --quiet
```

No output means the check passed. If it prints an error, correct that error
before continuing.

### Step 5: Build and start the stack

Run:

```bash
docker compose --env-file .env up -d --build
```

The first start can take several minutes because Docker builds the local images
and the containers download current Salvium and P2Pool binaries.

Check the services:

```bash
docker compose --env-file .env ps
```

The one-time `perms` service should show that it exited successfully. The main
services should be running; `salviumd` may show `starting` until its health
check passes.

### Step 6: Watch the first startup

Follow the important logs:

```bash
docker compose --env-file .env logs -f salviumd p2pool p2pool-watchdog
```

Press **Ctrl+C** when you are finished watching. This only closes the log view;
it does not stop the containers.

The node must synchronize before mining statistics become meaningful. Initial
synchronization time depends on the server and network connection.

### Step 7: Enable automatic failover

Only do this after `sidechain.json` is installed and P2Pool has started
successfully:

```bash
./ops/salvium-mode auto
```

Confirm the result:

```bash
./ops/salvium-mode status
```

You should see `desired mode : auto`. The active mode normally begins as
`public`.

### Step 8: Connect your miners

Use the Docker server's IP address and Stratum port `3333`:

```text
YOUR-SERVER-IP:3333
```

The payout wallet is already configured in `.env`. Public/private switching
does not change this Stratum address.

## Everyday commands

Run these commands from the repository directory.

### See whether everything is running

```bash
docker compose --env-file .env ps
```

### View recent logs

```bash
docker compose --env-file .env logs --tail=100
```

### Follow logs live

```bash
docker compose --env-file .env logs -f
```

Press **Ctrl+C** to leave the log view.

### Restart one service

```bash
docker compose --env-file .env restart p2pool
```

Replace `p2pool` with another service name if needed.

### Stop the stack

```bash
docker compose --env-file .env down
```

The blockchain and P2Pool files remain in `SALVIUM_DATA_ROOT`.

### Start it again

```bash
docker compose --env-file .env up -d
```

### Update repository files

Binary updates happen automatically, but changes to this repository do not.
To update the Compose files and scripts:

```bash
git pull
docker compose --env-file .env up -d --build
```

Read new release notes before applying repository changes to a production node.

## Controlling public and private modes

The helper automatically reads this repository's `.env` file.

### Show the current mode and watchdog state

```bash
./ops/salvium-mode status
```

### Let the watchdog choose automatically

```bash
./ops/salvium-mode auto
```

### Stay on public mode

```bash
./ops/salvium-mode public
```

### Stay on private mode

```bash
./ops/salvium-mode private
```

### Show the switching history

```bash
./ops/salvium-mode history
```

Selecting `public` or `private` pins that mode; the watchdog will not switch it.
Selecting `auto` returns control to the watchdog.

## Default watchdog timing

| Setting | Default | Meaning |
| --- | ---: | --- |
| Check interval | 60 seconds | How often mining health is evaluated |
| Failure time | 15 minutes | How long public mode must be unhealthy before fallback |
| Recovery time | 30 minutes | How long public peers must be reachable before a trial return |
| Minimum dwell | 1 hour | Minimum time before another mode switch |
| Trial window | 5 minutes | Time allowed for public mining to prove it is advancing |
| Stale statistics | 5 minutes | Age at which statistics are considered stale |
| Height stall | 10 minutes | Time without a sidechain-height advance before failure |

These values can be changed in `.env`. Beginners should use the defaults until
the stack is working reliably.

## Statistics page

Open:

```text
http://YOUR-SERVER-IP:3000
```

If the page does not open, check:

```bash
docker compose --env-file .env ps stats
docker compose --env-file .env logs --tail=100 stats
```

## Optional TrueNAS/ZFS backup helper

`ops/backup-salvium.sh` is intended for the original TrueNAS/ZFS layout. It:

1. Asks the daemon to flush blockchain data.
2. Creates a ZFS snapshot.
3. Makes a compressed archive.
4. Creates a SHA-256 checksum and tests the archive.
5. Retains the newest eight weekly archives by default.

This script creates and destroys ZFS snapshots and deletes expired backups.
Review its paths and environment-variable defaults before running it. Do not
use it unchanged on a non-ZFS server.

## Troubleshooting

### `P2POOL_WALLET` is required

Open `.env` and replace the example wallet value with your public Salvium
wallet address.

### A port is already in use

Change the corresponding host-side port in `.env`, then start the stack again.
For example, change `STATS_PORT=3000` if another application already uses port
3000.

### P2Pool fails when private mode is selected

Confirm this file exists:

```bash
DATA_ROOT="$(grep '^SALVIUM_DATA_ROOT=' .env | cut -d= -f2-)"
ls -l "$DATA_ROOT/p2pool/sidechain.json"
```

If it is missing, repeat Step 3.

### Automatic switching does not happen

Check the selected mode:

```bash
./ops/salvium-mode status
```

Automatic switching only happens when the desired mode is `auto`.

Then inspect the watchdog log:

```bash
docker compose --env-file .env logs --tail=200 p2pool-watchdog
```

### Permission errors

Check that `PUID` and `PGID` in `.env` identify the account that should own the
runtime files. The supplied values are `1000` and `1000`, matching the original
stack.

### The node is running but mining has not started

The daemon may still be synchronizing. Check:

```bash
docker compose --env-file .env logs --tail=100 salviumd
```

## Important security notes

- Never commit `.env`.
- Never put a seed phrase, private spend key, wallet password, or Portainer
  token in this repository.
- The health check uses local restricted RPC and contains no RPC credential.
- The updater and watchdog containers mount the Docker socket. Anyone who can
  change those containers or their scripts can control Docker on the host.
- P2Pool currently receives `SYS_ADMIN` and `IPC_LOCK` for the production
  hugepage/memory configuration.
- The default ports are published on the Docker host. Use firewall rules and
  do not expose RPC, statistics, or Stratum services directly to the internet
  unless you understand the consequences.
- Release downloads and some image references are not yet fully pinned and
  cryptographically verified. See `docs/security.md`.

## What is intentionally not included?

- Wallet files or keys
- Wallet passwords or seed phrases
- The production payout address
- The production RPC health-check credential
- `.env`
- Portainer tokens
- Blockchain databases
- P2Pool caches and peer state
- Statistics data and logs
- Audit reports and backups
- The separate Salvium staker stack

For deployment architecture, migration cautions, and security hardening, see:

- `docs/architecture.md`
- `docs/migration.md`
- `docs/security.md`

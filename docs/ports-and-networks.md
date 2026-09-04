# Ports and network boundaries

This document describes every TCP port used by the stack, who should be able
to reach it, and why. The defaults assume the Docker host is
`192.168.1.54`, trusted client devices receive addresses from
`192.168.1.0/24`, and the router does not forward private services from the
Internet.

The client devices do not need fixed addresses. `TRUSTED_LAN_CIDRS` authorizes
the trusted DHCP subnet as a group. If guest or IoT devices share that subnet,
move them to a separate VLAN before treating the subnet as trusted.

## Port policy

| Host port | Container | Function | Allowed sources | Internet forward |
| --- | --- | --- | --- | --- |
| `19080` | `salviumd` | Salvium blockchain P2P | Public peers and LAN | Optional |
| `19081` | `salviumd` | Unrestricted daemon RPC | `salvium_privileged_rpc` only | Never |
| `19083` | `salviumd` | ZMQ block, transaction, and miner-data publisher | `salvium-p2pool` on `salvium_node` | Never |
| `19089` | `salviumd` | Restricted wallet-facing RPC | Trusted LAN plus explicitly configured client subnets | Never; use a VPN remotely |
| `3333` | `salvium-p2pool` | Stratum mining | Trusted LAN miners | Never |
| `38888` | `salvium-p2pool` | Private/custom P2Pool sidechain P2P | Trusted private peers or VPN | Only to known private peers |
| `38889` | `salvium-p2pool` | Public P2Pool sidechain P2P | Public peers and LAN | Optional when public mode is active |
| `3000` | `salvium-stats` | Web statistics dashboard | Trusted LAN browsers | Never |

Host bindings are explicit. `19089`, `3333`, `38888`, and `3000` bind to the
configured LAN address rather than every host interface. Public peer ports use
`PUBLIC_BIND_IP`. IPv6 host publishing is not enabled by the Compose mappings.

## Why port 19081 is privileged

Port `19081` is Salvium's unrestricted daemon RPC server. Among other methods,
it permits callers to start and stop daemon CPU mining, select a mining payout
address, stop the daemon, change peer limits and bans, flush transaction and
cache state, select a bootstrap daemon, trigger update behavior, and pop local
blocks.

It does not directly provide a TrueNAS shell or wallet private keys, but an
unauthorized caller can control or disrupt important node behavior. The stack
therefore does not publish `19081` on any host address. The two staker
wallet-RPC services join the internal `salvium_privileged_rpc` Docker network
and connect to `salviumd:19081` by service name.

Normal desktop wallets and the Hummingbot view-only wallet use restricted RPC
on `192.168.1.54:19089`.

Primary references:

- [Salvium source: RPC route restrictions](https://github.com/salvium/salvium/blob/v1.1.3c/src/rpc/core_rpc_server.h)
- [Salvium operator warning for public remote nodes](https://github.com/salvium/salvium#known-issues)
- [Salvium block explorer restricted-RPC example](https://github.com/salvium/salvium-blockchain-explorer)

## Stratum and its HTTP surface

P2Pool normally multiplexes Stratum mining and a small HTTP statistics API on
the Stratum listener. This stack keeps `--stratum-api` so P2Pool writes local
worker statistics into the data directory. Miners continue to use
`192.168.1.54:3333`; HTTP requests to `/`, `/local/stratum`, and `/local/p2p`
are accepted only from `TRUSTED_LAN_CIDRS` by the host binding and firewall.
Never forward port `3333` from the router.

During production validation, P2Pool Salvium v4.28 exited with code 139 after
sidechain synchronization when `--no-stratum-http` was enabled. The option was
therefore not deployed. Re-test that option after a later upstream P2Pool
release before considering it safe for this stack.

See the [P2Pool command-line reference](https://github.com/SChernykh/p2pool/blob/master/docs/COMMAND_LINE.MD).

## Docker networks

| Network | Members | Internet gateway | Purpose |
| --- | --- | --- | --- |
| `salvium_node` | `salviumd`, `salvium-p2pool` | Yes | Blockchain and public P2Pool traffic; internal restricted RPC and ZMQ |
| `salvium_privileged_rpc` | `salviumd`, two staker wallet-RPC services | No | Externally managed cross-stack network for unrestricted RPC only |
| `salvium_stats` | `salvium-stats` | Yes | Isolates the dashboard from daemon and P2Pool container addresses |
| `salvium_management` | updater and watchdog services | Yes | Release checks and watchdog peer probes |
| Host network | `salvium-firewall` | Host | Installs narrowly scoped forwarded- and host-ingress rules |

The statistics application receives P2Pool data through a read-only bind mount;
it does not need to share a Docker network with the node. Updaters and the
watchdog retain outbound access but do not share the node network.

Private mode requires at least one reachable P2Pool peer from the private
mode's `p2pool_peers.txt`. DHCP mining clients are Stratum clients, not P2Pool
peers, and do not satisfy this requirement. Before enabling automatic mode,
pin private mode once and confirm both private P2Pool port `38888` and Stratum
port `3333` become reachable. The watchdog refuses an automatic fallback when
the retained private peer list has no reachable endpoint.

Create or validate the cross-stack network before deployment:

```sh
./scripts/create-privileged-network.sh .env
```

## Host firewall behavior

Docker evaluates ordinary published-port forwarding in `DOCKER-USER`.
Connections originating from another local Docker bridge can instead reach the
userland proxy through host `INPUT`. The `salvium-firewall` service covers both
paths with dedicated `SALVIUM-INGRESS` and `SALVIUM-HOST-INGRESS` chains.

The chain permits the configured source CIDRs and drops other forwarded
connections to restricted RPC, Stratum, the dashboard, and the private P2Pool
port. It does not alter public peer access to `19080` or `38889`. The service
has host networking and `NET_ADMIN`, but no Docker socket, host filesystem
mount, or listening network service.

The forwarded rules match only the original client-to-container direction and
the configured host LAN destination address. Reply traffic and P2Pool's own
outbound peer connections are deliberately excluded.

Inspect the live policy:

```sh
docker exec salvium-firewall /usr/local/sbin/salvium-firewall check
iptables -S DOCKER-USER
iptables -S SALVIUM-INGRESS
iptables -S INPUT
iptables -S SALVIUM-HOST-INGRESS
```

Remove only this stack's policy during a rollback:

```sh
docker exec salvium-firewall /usr/local/sbin/salvium-firewall remove
```

## Router and remote access

`--no-igd` prevents Salvium and P2Pool from creating automatic router mappings.
Only `19080` and the active public P2Pool peer port should be considered for a
manual forward. Do not forward `19081`, `19089`, `3333`, `38888`, or `3000` to
the public Internet. Use a VPN to reach wallet RPC or statistics from outside
the trusted LAN.

Docker references:

- [Published ports bind to all addresses unless a host address is specified](https://docs.docker.com/engine/network/port-publishing/)
- [Filtering published ports in `DOCKER-USER`](https://docs.docker.com/engine/network/firewall-iptables/)
- [User-defined bridge isolation](https://docs.docker.com/engine/network/drivers/bridge/)

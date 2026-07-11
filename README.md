# Tunnel Manager

A single interactive panel for running reverse tunnels between two Linux servers — commonly an "IRAN" server (the side users actually connect to) and a "KHAREJ" server (where the real backend lives, reached through the tunnel). One `curl | bash` install gets you a menu-driven tool that can install, configure, diagnose, benchmark, back up, watch over, and remove tunnels across six different tunnel engines, without needing to hand-edit a single config file.

This isn't a wrapper around one tool. Each engine is a self-contained module (`core/<name>/core.sh`) that speaks that engine's real config format and follows that engine's own design — see [`core/README.md`](core/README.md) if you're extending it.

## Contents

- [Supported tunnel engines](#supported-tunnel-engines)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Menu reference](#menu-reference)
- [Choosing an engine](#choosing-an-engine)
- [Advanced usage](#advanced-usage)
- [Security](#security)
- [Backups](#backups)
- [Health monitoring](#health-monitoring)
- [Network optimization](#network-optimization)
- [Migrating to a new VPS](#migrating-to-a-new-vps)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Developing / adding a new engine](#developing--adding-a-new-engine)
- [Roadmap](#roadmap)

## Supported tunnel engines

| Engine | Protocol | Best for | Guide |
|---|---|---|---|
| **Backhaul** | TCP (+ TUN/IPX helper modes) | The default choice — highest raw throughput, most mature in this panel, most configuration depth (port ranges, IPX encapsulation, kernel tuning, forwarder engines) | [docs/backhaul.md](docs/backhaul.md) |
| **Rathole** | TCP | A simpler, Rust-based alternative to Backhaul — smaller surface area, fast to reason about | [docs/rathole.md](docs/rathole.md) |
| **GOST** | TCP/UDP, chainable | Not a simple A↔B tunnel — a general proxy/forwarding toolkit with protocol chaining, useful when you need something Backhaul/Rathole can't express | [docs/gost.md](docs/gost.md) |
| **Hysteria2** | QUIC (UDP) | Links with active DPI, throttling, or heavy packet loss — congestion control tuned for exactly that | [docs/hysteria2.md](docs/hysteria2.md) |
| **FRP** | TCP | The most widely deployed reverse-proxy tunnel in the ecosystem — huge community, very stable | [docs/frp.md](docs/frp.md) |
| **TUIC** | QUIC (UDP) | Same niche as Hysteria2, lighter weight — worth trying if Hysteria2 underperforms on a specific link | [docs/tuic.md](docs/tuic.md) |

If you're not sure which to pick: start with **Backhaul** (the default, most-featured path). Move to **Hysteria2** or **TUIC** specifically if your link is filtered/throttled and TCP-based tunnels get degraded. See [Choosing an engine](#choosing-an-engine) below for the full comparison.

## Installation

Run as root on **both** servers (the one users connect to, and the one with the real backend):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dr-hoseyn/tunnel-manager/main/install.sh)
```

This installs to `/opt/tunnel-manager`, downloads the Backhaul core binary with SHA256 verification, and creates two equivalent launcher commands: `backhaul` and `tunnel-manager`. Either one opens the panel:

```bash
backhaul
# or
tunnel-manager
```

Other engines (Rathole, GOST, Hysteria2, FRP, TUIC) download their own binaries on first use, from their own upstream GitHub releases, the first time you open that engine's menu.

## Quick start

The most common setup: expose a service that lives on your KHAREJ server, through your IRAN server, using Backhaul.

**On IRAN (the server end users connect to):**
1. Run `backhaul`, choose **1) Configure a new tunnel**, then **1) Configure IRAN (Server)**.
2. Accept the suggested transport, bind port, and token (or set your own) — every prompt shows a smart default; press Enter to accept it.
3. Enter the ports you want forwarded (e.g. `443` or `443,8080=9090`).

**On KHAREJ (where the real backend runs):**
1. Run `backhaul`, choose **1) Configure a new tunnel**, then **2) Configure KHAREJ (Client)**.
2. Enter IRAN's address (`IP:Port`) — matches what you set as the bind port above.
3. Use the same token you set on IRAN.

The panel runs diagnostics automatically right after each side is configured, and both sides register a systemd service (`backhaul-iranPORT.service` / `backhaul-kharejPORT.service`) with a watchdog timer that restarts it if it ever goes down.

## Menu reference

```
1. Configure a new tunnel        \
2. Tunnel management              } Backhaul — the default engine, wired
3. Check tunnel status            / directly at the top level (no submenu)
──────────────────────────────────
4. Rathole
5. GOST Manager
6. Hysteria2 (QUIC, DPI/throttling resistant)
7. FRP
8. TUIC (QUIC, lightweight alternative)
──────────────────────────────────
9. Dashboard (live CPU/RAM/network + tunnel status)
10. Security & Maintenance (TLS cert, Fail2Ban)
11. Optimize Network (BBR, buffers, conntrack, port reservation)
──────────────────────────────────
12. Update Backhaul Core
13. Update script
14. Remove Backhaul Core
15. Uninstall everything
0. Exit
```

Every other engine (4–8) opens its own submenu with the same shape: **Configure a new tunnel**, **Tunnel management** (edit/diagnose/benchmark/logs/restart/remove any existing tunnel), **Check tunnel status**, plus an **Update core** action.

## Choosing an engine

| | Backhaul | Rathole | GOST | Hysteria2 | FRP | TUIC |
|---|---|---|---|---|---|---|
| Transport | TCP / TUN+IPX | TCP | TCP/UDP | QUIC | TCP | QUIC |
| Obfuscation against DPI | Partial (anytls/wss) | No | Via chaining | Yes (Salamander) | No | Yes (via SNI/skip-verify) |
| Config depth in this panel | Highest | Low | Highest (chains) | Medium | Medium | Medium |
| Maturity / ecosystem size | High | Medium | High | High | Very high | Medium |
| Good on lossy/throttled links | Depends on transport | No | Depends on chain | Yes | No | Yes |
| Raw throughput ceiling | Highest | High | High | Good | High | Good |

Rules of thumb:
- **Clean, unfiltered link, want the most control** → Backhaul.
- **Want the simplest possible TCP tunnel** → Rathole.
- **Need to chain multiple protocols/hops, or do something Backhaul/Rathole's models don't fit** → GOST.
- **Link is actively throttled or DPI'd, TCP tunnels keep degrading** → Hysteria2, then TUIC if Hysteria2 underperforms.
- **Want the tool with the largest community/most third-party tooling around it** → FRP.

Each engine's guide (linked in the table above) covers protocol tradeoffs, security model, and concrete recommended configurations in depth.

## Advanced usage

**Editing a tunnel** (any engine, via that engine's *Tunnel management*): every field is prefilled with its current value, not a generic default — pressing Enter keeps it unchanged. Behind the scenes this backs up the current config + systemd unit, applies your changes, and automatically rolls back if the service doesn't come back healthy within a few seconds.

**Diagnostics**: checks the local service, pings the peer (if its IP is set), checks the peer's SSH port, and does a final end-to-end reachability check on the first forwarded port.

**Benchmark**: TCP and ICMP probes against the peer, with a real-throughput number if `iperf3 -s` happens to be running there.

**Smart defaults**: every prompt that has a sensible default shows it — last-used values (transport, remote address, peer IP), detected values (public IPv4/IPv6, network interface, free ports), or computed recommendations (a free port that doesn't collide with another tunnel *or* an already-listening process on the system).

## Security

- Every engine's binary is downloaded with checksum verification where upstream publishes one (Backhaul, Rathole, Hysteria2, FRP). TUIC's upstream (`Itsusinn/tuic`) doesn't publish checksums, so that one installs unverified over HTTPS — see [docs/tuic.md](docs/tuic.md).
- TLS: a single self-signed cert (`/root/backhaul-core/cert_files/`) is shared by Backhaul's TLS transports, Hysteria2, and TUIC. It's checked every watchdog cycle (every 5 minutes) and auto-renewed inside 30 days of expiry, restarting whatever's using it. This is a shared-secret trust model (token/password/UUID), not CA-validated identity — there's no in-panel channel to move a cert fingerprint between two independently-managed servers, so clients are configured to skip cert verification and rely on the auth secret instead.
- **Security & Maintenance → Enable Fail2Ban SSH protection** sets up a standard sshd jail (5 failed attempts in 10 minutes → 1 hour ban). Off by default — it changes system-wide SSH ban behavior, so it's an explicit action, not something the installer does silently.
- Firewall rules for forwarded ports are added automatically (iptables, plus ufw if it's active) when you configure a tunnel.

## Backups

Editing or updating a tunnel automatically snapshots the current config + systemd unit into `/root/backhaul-core/.backups/` before touching anything, and rolls back automatically if the new version doesn't come up healthy. This is safety-net backup (protects you from a bad edit), not a portable export — see [Migrating to a new VPS](#migrating-to-a-new-vps) for moving a working setup elsewhere.

## Health monitoring

A systemd timer (`backhaul-watchdog.timer`) runs every 5 minutes and, per engine, restarts any tunnel service that should be running but isn't. It also renews the shared TLS cert when needed (see [Security](#security)). This installs automatically the first time you configure any tunnel — there's nothing to turn on separately.

## Network optimization

**Optimize Network** (menu item 11) tunes the underlying OS/kernel network stack — this is independent of, and complementary to, each engine's own tuning options (e.g. Backhaul's `so_rcvbuf`/`so_sndbuf`/`mss`/mux settings). It applies:

- Larger socket buffers (`rmem`/`wmem`, max *and* default), backlog, and connection-capacity sysctls sized for holding many concurrent tunnel connections.
- BBR + `fq` where the kernel supports it — persisted across reboots (`/etc/modules-load.d`) and applied immediately to already-up interfaces via `tc qdisc replace` (`net.core.default_qdisc` alone only affects newly-created interfaces).
- Connection-tracking tuning (`nf_conntrack_max`/hashsize) when the kernel/namespace exposes it — tolerated, not fatal, on containers (OpenVZ/LXC) where it doesn't.
- Ephemeral-port reservation: every port already in `LISTEN` state (across every engine, not just Backhaul) is added to `net.ipv4.ip_local_reserved_ports`, so the deliberately wide ephemeral range this panel needs for high concurrency never gets handed out as an outgoing port that collides with a tunnel's own bind port. This is a snapshot taken at apply time — re-run it after configuring a new tunnel/port.
- TCP keepalive tuning for long-lived tunnel connections, `tcp_fastopen`, `tcp_no_metrics_save`.
- A systemd `DefaultLimitNOFILE` drop-in for services *other* than this panel's tunnels — every engine here already sets `LimitNOFILE=1048576` on its own systemd unit, so this only matters for unrelated services on the box.

Every run snapshots the prior state into `/root/backhaul-core/.backups/network-tune.<timestamp>/`, and **Roll back** in the same menu removes everything it added. Uninstalling everything also rolls this back automatically if it was ever applied.

This is the same tuning as the standalone [vm-network-tuner](https://github.com/dr-hoseyn/vm-network-tuner) script, wired into this panel's menu/backup conventions instead of being a separate one-shot script.

## Migrating to a new VPS

There's no one-click export yet (see [Roadmap](#roadmap)). Today, moving a working tunnel to a new server means copying the relevant files by hand:

- Config: the engine's own file under `/root/backhaul-core/` (Backhaul: `iranPORT.toml` at the root; other engines: `<engine>/iranPORT.toml` or `.yaml`).
- The engine's own binary, if you'd rather not re-download it.
- `/root/backhaul-core/cert_files/` if the tunnel uses TLS.
- `/root/backhaul-core/.meta/<config_name>.meta` for the peer IP/SSH port diagnostics remember.

Then re-run that engine's **Edit** flow once on the new server so the systemd service gets (re)created correctly, rather than hand-writing the unit file.

## Troubleshooting

**A tunnel won't connect after configuring it.**
1. Check the service is actually active: that engine's *Tunnel management* → pick the tunnel → **View service status** / **View service logs**.
2. Re-run **Retest (Diagnostics)** on the tunnel — it'll tell you specifically which side isn't ready (local service down, peer unreachable, or forwarded port not answering yet).
3. Confirm both sides used the *same* shared secret (token/password/UUID depending on engine) and the same port.
4. For QUIC-based engines (Hysteria2, TUIC): confirm the port is actually open for **UDP**, not just TCP — a firewall or provider that only opens TCP will silently break these.

**"Remove Backhaul Core" or "Update Backhaul Core" seems to affect the wrong thing.** These only ever touch the `backhaul_premium` binary — they don't remove your tunnels or any other engine's data. If you're removing everything, use **Uninstall everything** instead.

**A cert-related error after upgrading.** The shared self-signed cert auto-renews inside 30 days of expiry (see [Security](#security)); if a tunnel was mid-handshake during a renewal-triggered restart, it'll reconnect within a few seconds on its own (systemd `Restart=always`).

## FAQ

**Do I need to run the installer on both servers?**
Yes — each server runs its own independent copy of the panel and manages its own tunnels. There's no central coordinator (see [Roadmap](#roadmap) for multi-server management).

**Can I run multiple engines at once?**
Yes. Each engine uses its own port range/config directory/systemd service naming, so a Backhaul tunnel and a Hysteria2 tunnel can run side by side without conflicting — the panel checks for port collisions across the whole system (not just its own configs) when suggesting a port.

**What happens if I lose SSH access after enabling Fail2Ban?**
The default jail is 5 failed attempts in 10 minutes before an hour-long ban, scoped to failed SSH logins — a legitimate session with the right key/password is never affected. If you do get banned from your own IP, wait it out or access the server through your provider's console and run `fail2ban-client unban <your-ip>`.

**Where does everything live on disk?**
`/root/backhaul-core/` for all config/certs/backups/metadata, `/opt/tunnel-manager/` for the panel code itself. `/root/backhaul-core` is a legacy name from before the panel supported multiple engines — it's shared by all of them now.

## Developing / adding a new engine

See [`core/README.md`](core/README.md) for the plugin interface every engine implements, the common internal shape to follow, and a step-by-step checklist. In short: one new `core/<name>/core.sh`, four wiring points in `tunnel-manager.sh` (source it, watchdog loop, uninstall, menu entry) — `install.sh` needs no changes since it copies `core/` recursively.

When changing shared code (`lib/common.sh`, or anything in `core/backhaul/core.sh` that other engines depend on), run the full test pass before pushing: `bash -n` and `shellcheck -s bash` on every changed file, plus re-running each engine's own test coverage if one exists for the area you touched.

## Roadmap

Not yet implemented, in rough priority order:
- One-click config export/import for VPS migration (today this is a manual file-copy, see above)
- Multi-server management from a single interface (each install is currently fully independent)
- A live dashboard (CPU/RAM/bandwidth/connections across all tunnels in one view)
- Searchable audit log (who changed what, when, old value → new value)
- Rate limiting on forwarded ports
- FRP/TUIC checksum verification once upstream publishes one for TUIC (FRP's is already verified)

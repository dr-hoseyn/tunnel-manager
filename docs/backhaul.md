# Backhaul

## What it is

Backhaul is the original engine this panel was built around, and it's still the default: a TCP-based (with an optional TUN/IPX helper mode) reverse tunnel between two servers, with the deepest configuration surface of any engine in this panel — port ranges, kernel tuning, multiple TCP transport variants, and pluggable forwarding engines for the TUN mode.

## How it works

Two roles, matching the panel's IRAN (server, listens) / KHAREJ (client, dials out) convention:

- **IRAN (server)** binds a port and accepts the tunnel connection from KHAREJ. Forwarded ports are configured on this side — end users connect to IRAN, traffic flows through the tunnel to KHAREJ.
- **KHAREJ (client)** dials out to IRAN's address and forwards the actual backend traffic to a local address.

Transports available in this panel: `tcp`, `tcpmux`, `xtcpmux`, `ws`, `wss`, `wsmux`, `wssmux`, `xwsmux`, `anytls`, `tun`. The `mux` variants multiplex multiple logical streams over fewer underlying connections; `ws`/`wss` disguise traffic as WebSocket; `anytls` adds a TLS layer with a configurable SNI for camouflage.

**TUN mode** is a separate, more involved path: instead of Backhaul forwarding specific TCP ports itself, it brings up a TUN network interface between the two servers and hands actual packet forwarding to one of four pluggable engines you pick per-tunnel:
- `backhaul` — Backhaul's own internal TCP-only proxy, zero extra setup.
- `iptables` — kernel-level DNAT, supports both TCP and UDP, lowest overhead.
- `haproxy` — userspace TCP proxy with backend health-checking.
- `ipvs` — kernel-level load balancer (`ipvsadm`), TCP and UDP.

TUN mode also supports an `ipx` encapsulation submode (profiles: `icmp`, `ipip`, `udp`, `tcp`, `gre`, `bip`) for cases where you specifically need to tunnel over a non-standard protocol.

### Tunnel Health engine

The five-minute watchdog records a lightweight per-tunnel health sample for TUN/IPX. It combines control/near-MTU probes with TUN and underlay drops/errors, qdisc drops, service CPU/RAM/restarts/traffic, system load, memory pressure, and conntrack occupancy. A bounded 24-hour TSV history and an atomic latest snapshot are stored under `.health`.

The result is a single root-cause classification with a confidence score. Ambiguous underlay failure stays low-confidence and all non-MTU diagnoses block Smart Auto-MTU. Use **Tunnel management > Tunnel Health** for a fresh sample, detailed counters, and recent history.

### Smart Auto-MTU for TUN/IPX

TUN/IPX can enable a per-tunnel adaptive MTU controller. It does not react to ordinary packet loss by blindly lowering MTU. A small probe first verifies that the general tunnel path is healthy; only a repeatable difference between small and near-MTU probes is considered size-specific evidence.

Continuous VPN traffic is supported: Auto-MTU uses the Tunnel Health classification to reject unsafe congestion or resource-pressure windows, rather than requiring the tunnel to become idle or relying on systemd service traffic counters that may not include forwarded VPN packets.

- Defaults: current `1320`, allowed range `1200-1420`, step `20` (all configurable).
- Downward change: two consecutive black-hole/large-packet failures while small probes remain healthy.
- Upward change: three consecutive clean checks, followed by a larger candidate probe.
- Every candidate restarts the service only during low traffic, runs an A/B comparison, and is kept only if its delivery score improves. Failure, ambiguous results, or a degraded small probe cause immediate rollback.
- Checks pause on high traffic, high CPU load, missing systemd traffic accounting, a recently restarted service, or cooldown. This is deliberately slower than an aggressive optimizer because avoiding a wrong change matters more than finding the theoretical maximum quickly.
- The Tunnel Health gate must also report `healthy` or `mtu-suspected`; stale or unrelated diagnoses fail closed.

Open **Tunnel management**, select the IPX tunnel, then choose **Smart Auto-MTU** to run one guarded evaluation, toggle automation, change limits, or reset learned history. Both ends should use compatible bounds; each side still evaluates its own outbound path independently.

## Advantages

- Highest raw throughput ceiling of the engines in this panel for plain TCP traffic.
- Most mature and most exercised in this panel — every prompt has smart defaults, full edit/backup/rollback, diagnostics, and benchmark support.
- Deepest configuration: port ranges (`443-600`), remapping (`443=5000`), kernel tuning profiles, mux tuning, four different forwarding engines for TUN mode.
- `anytls`/`wss` transports give some DPI camouflage without switching engines entirely.

## Disadvantages

- Plain `tcp` transport has no obfuscation — trivially fingerprinted by DPI as a raw TCP stream on a non-standard port.
- TUN mode is the most complex path to get right (kernel prerequisites, firewall rules, forwarder engine choice) — the panel automates the setup, but there's more that can go wrong than with a simple port-forward.
- No QUIC/UDP-native option — for a genuinely throttled or lossy link, Hysteria2 or TUIC's congestion control will usually do better.

## Performance

Best-in-panel for sustained TCP throughput on a clean link, especially with `tcpmux`/`wssmux` reducing per-connection overhead. TUN mode with the `iptables` forwarder adds the least overhead of the four forwarding engines; `haproxy` adds the most (but gives you backend health-checking in return).

## Security

- Shared-token auth (`Security Token`, plain `tcp`/`ws` transports) or, in IPX mode, full encryption (AES-256-GCM by default, PSK + KDF iterations configurable).
- `anytls`/`wss` add TLS using the panel's shared self-signed cert (see the main [Security](../README.md#security) section) — this hides the traffic *shape* behind TLS but doesn't add certificate-based trust; the token is still the real auth boundary.
- No protocol-level obfuscation on plain `tcp` — if DPI resistance matters more than throughput, use Hysteria2 or TUIC instead.

## Best use cases

- You control both ends and the link isn't actively filtered — maximize throughput.
- You need TUN-level forwarding (UDP services, whole port ranges, or a specific forwarder engine's health-checking).
- You're already running Backhaul and it works — the panel's backward-compatibility guarantee means upgrading the panel never changes how existing Backhaul tunnels behave.

On the IRAN side, **Edit tunnel > Manage forwarded ports** can change both individual port mappings and the active TUN forwarder (`backhaul`, `iptables`, `haproxy`, or `ipvs`). The switch is transactional: the previous config and forwarding rules are restored if the replacement cannot start cleanly.

## When not to use it

- The link is actively throttled/DPI'd and plain TCP tunnels keep getting degraded or reset — try Hysteria2 or TUIC first.
- You want the absolute simplest possible config with the smallest attack surface — Rathole is lighter.

## Recommended configuration

For a straightforward "expose these ports" tunnel on a clean link: `tcp` transport, `nodelay` on, default kernel tuning profile (`balanced`). For a link under light interference: `wss` transport with a realistic SNI. For anything needing UDP or a full port range: TUN mode with the `iptables` forwarder.

## Menu path

Wired directly at the top level (not behind a submenu, since it's the highest-traffic action): **1) Configure a new tunnel**, **2) Tunnel management**, **3) Check tunnel status**.

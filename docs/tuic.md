# TUIC

## What it is

TUIC is another QUIC-based (UDP) tunnel protocol, occupying the same niche as Hysteria2 — designed for filtered/throttled/lossy links — but with a lighter-weight implementation and a smaller ecosystem.

**A note on upstream provenance**, since it affects where this panel installs from: the original `EAimTY/tuic` project is inactive, and the current `tuic-protocol/tuic` GitHub org is now just the protocol specification with no combined server+client binary release. This panel installs from [`Itsusinn/tuic`](https://github.com/Itsusinn/tuic) instead — the actively maintained implementation that `tuic-protocol/tuic`'s own README lists as a reference implementation, and the only one currently publishing server+client binaries together in one release.

## How it works

Same server/client split as the other engines, using UUID+password authentication (a pair, not a single shared secret like the other five engines) — IRAN runs the server (`[users]` table mapping UUID → password), KHAREJ runs the client (`[relay]` with matching `uuid`/`password`). Port forwarding lives on the client (KHAREJ) side via `[[local.tcp_forward]]`, matching Hysteria2's convention (not Backhaul/Rathole/FRP's) — `listen` is where the client itself listens, `remote` is an address reachable from the server (IRAN) side.

## Advantages

- Same QUIC-based DPI/throttling resistance profile as Hysteria2, worth trying as an alternative if Hysteria2 specifically underperforms on a given link.
- Lighter-weight implementation than Hysteria2 in some deployments.
- UUID+password auth is a slightly larger secret space than a single shared token.

## Disadvantages

- **No published checksums** for the binaries this panel installs from (`Itsusinn/tuic`'s releases don't include a checksums file) — installation is unverified beyond HTTPS transport security, unlike every other engine in this panel. See [Security](#security).
- Smaller community/ecosystem than Hysteria2 or FRP — less prior art if something goes wrong.
- Upstream project history is more fragmented (see the provenance note above) — worth knowing if you're evaluating long-term maintenance risk.

## Performance

Comparable to Hysteria2 on lossy/throttled links given both use QUIC; the actual difference between the two on any specific link is worth testing directly (configure both, run **Benchmark** on each) rather than assuming — congestion control tuning differs between implementations in ways that are link-dependent.

## Security

- UUID+password pair, matched on both sides.
- Server TLS uses the panel's shared self-signed cert; the client sets `skip_cert_verify = true` for the same reason Hysteria2's client sets `insecure: true` — no in-panel channel exists to move a cert fingerprint between two independently-managed servers. The UUID+password pair is the real trust boundary.
- **Binary installation is unverified** (no upstream checksums) — this is the one meaningful security gap relative to the other five engines in this panel, all of which verify a checksum where upstream publishes one. If that matters for your threat model, consider building `tuic-server`/`tuic-client` from source yourself and placing the binaries at `${config_dir}/tuic/tuic_server_bin` / `tuic_client_bin` before configuring a tunnel.

## Best use cases

- Same as Hysteria2: actively throttled/DPI'd links.
- Specifically when Hysteria2 underperforms and you want a second QUIC-based option to compare against on the same link.

## When not to use it

- The link is clean and unfiltered — a TCP engine will outperform it with less overhead.
- Binary integrity verification matters for your threat model and you're not willing to build from source (see Security above).

## Recommended configuration

Set a realistic SNI (the panel defaults to a plausible domain) for traffic-shape camouflage, same reasoning as Hysteria2. `bbr` congestion control is used by default and isn't currently exposed as a choice in this panel.

## Menu path

**8) TUIC** → its own submenu: Configure a new tunnel / Tunnel management / Check tunnel status / Update TUIC core.

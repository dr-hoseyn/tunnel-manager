# Rathole

## What it is

Rathole ([rathole-org/rathole](https://github.com/rathole-org/rathole)) is a lightweight, Rust-based reverse tunnel — the simplest engine in this panel, both in what it exposes and in how little there is to configure wrong.

## How it works

Same IRAN (server) / KHAREJ (client) split as Backhaul: IRAN binds a control address and one or more named services (each a port to forward); KHAREJ dials out to IRAN and forwards each named service to a local address. Auth is a single shared token (`default_token`), the same on both sides.

This panel currently generates plain TCP configs only — Rathole itself also supports `tls` and `noise` transports upstream, but the config generator here (`core/rathole/core.sh`) is written so adding either is a new case branch, not a rewrite, if that becomes worth exposing later.

## Advantages

- Smallest, simplest config of any engine here — one token, a control address, a comma-separated port list.
- Rust implementation: low memory footprint, fast startup, no runtime dependencies beyond the single binary.
- Straightforward to reason about when debugging — few moving parts.

## Disadvantages

- No obfuscation in this panel's config (plain TCP) — same DPI-fingerprinting exposure as Backhaul's plain `tcp` transport.
- No TUN/UDP forwarding path — TCP port forwarding only.
- Smaller feature surface than Backhaul overall (no kernel tuning, no mux variants, no multiple forwarder engines).

## Performance

Comparable to Backhaul's plain `tcp` transport for straightforward port forwarding — Rathole's Rust runtime keeps overhead low, though this panel doesn't expose the same depth of tuning knobs (buffer sizes, mux concurrency) that Backhaul does.

## Security

Shared-token auth only, no encryption layer configured by this panel. Treat it the same as Backhaul's plain `tcp` transport from a threat-model standpoint: fine on a link you trust or one already wrapped by something else, not something that resists active DPI on its own.

## Best use cases

- You want the least amount of moving parts for a plain TCP port forward.
- You're comparing engines for a specific link and want a fast, low-overhead baseline against Backhaul.

## When not to use it

- You need DPI resistance — nothing in this panel's Rathole config obfuscates the traffic; use Hysteria2 or TUIC instead.
- You need UDP forwarding, port ranges, or kernel-level forwarding engines — that's Backhaul's TUN mode.

## Recommended configuration

Default token generation is fine (auto-generated, 20 random alphanumeric characters) — just make sure it matches on both sides, which the panel's edit-prefill and last-used defaults make easy to get right on subsequent tunnels.

## Menu path

**4) Rathole** → its own submenu: Configure a new tunnel / Tunnel management / Check tunnel status.

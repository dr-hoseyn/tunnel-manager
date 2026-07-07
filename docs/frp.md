# FRP

## What it is

FRP ([fatedier/frp](https://github.com/fatedier/frp)) is the most widely deployed reverse-proxy tunnel in this space — huge community, extremely stable, years of production use across a very large userbase. This panel wraps its core TCP reverse-proxy use case.

## How it works

Same shape as Backhaul/Rathole: IRAN runs `frps` (server, binds a port, holds the shared auth token), KHAREJ runs `frpc` (client, dials out, defines `[[proxies]]` entries). The forwarded-port config lives on the **client** (KHAREJ) side, matching FRP's own config format — `remotePort` is what opens on IRAN (frps) for end users to hit, `localPort`/`localIP` is where the real service is reachable from KHAREJ's (frpc's) machine. This is the same "forwarded port on IRAN, real backend reachable from KHAREJ" shape Backhaul and Rathole already use.

This panel generates plain TCP proxies only — FRP itself also supports `http`/`https`/`stcp`/`xtcp`/`tcpmux` proxy types and a whole HTTP virtual-hosting layer, none of which are exposed here.

## Advantages

- Largest ecosystem and community of any engine in this panel — most third-party tooling, most prior art if something goes wrong.
- Very mature codebase with a long production track record.
- Two independent binaries (`frps`/`frpc`) rather than one binary with a mode flag — slightly smaller attack surface per role.

## Disadvantages

- Plain TCP, no protocol obfuscation exposed by this panel — same DPI-fingerprinting exposure as Backhaul's plain `tcp` transport or Rathole.
- This panel only exposes the TCP proxy type; FRP's HTTP/HTTPS virtual hosting, `stcp`/`xtcp` (P2P-style hole punching), and dashboard features aren't wired up here.

## Performance

Comparable to Rathole and Backhaul's plain TCP transport for straightforward port forwarding — mature Go implementation, well-optimized for the common case.

## Security

Shared-token auth (`auth.token`, matched on both sides), no encryption layer configured by this panel. Same threat model as Backhaul's plain `tcp` or Rathole: fine on a trusted or already-wrapped link, not something that resists active DPI on its own.

## Best use cases

- You want the tunnel engine with the largest community and most external documentation/tooling to fall back on.
- You're already familiar with FRP from other projects and want consistent behavior.

## When not to use it

- You need DPI resistance — use Hysteria2 or TUIC.
- You need the HTTP/HTTPS virtual-hosting or P2P (`stcp`/`xtcp`) features FRP supports upstream — this panel doesn't expose them; you'd need to hand-edit the generated config.

## Recommended configuration

Default settings are fine for a straightforward port forward. Auto-generated 20-character token is sufficient; just keep it consistent across edits, which the panel's prefill defaults handle automatically.

## Menu path

**7) FRP** → its own submenu: Configure a new tunnel / Tunnel management / Check tunnel status / Update FRP core.

# GOST

## What it is

GOST ([go-gost/gost](https://github.com/go-gost/gost)) is not a simple A↔B tunnel like the other five engines — it's a general-purpose proxy and forwarding toolkit built around composable handlers, listeners, and chains. This panel treats it as a genuinely independent subsystem rather than another Backhaul clone, with its own config builder and its own mental model.

## How it works

Unlike every other engine here, GOST in this panel is **one service, one config file** (`gost.service` / `gost.yaml`), assembled from per-entity fragments (`services.d/*.yaml`, `chains.d/*.yaml`) rather than one service-per-tunnel. Two building blocks:

- **Services** — a listener (how traffic arrives), a handler (what protocol it speaks), and a forwarder (where it goes). Handler types available in this panel: `tcp`, `udp`, `rtcp`, `rudp`, `http`, `socks5`, `relay`. Transport types for the listener/dialer side: `tcp`, `tls`, `ws`, `wss`, `quic`, `kcp`, `grpc`, `h2`.
- **Chains** — multi-hop paths a service can route through, each hop with its own connector/dialer. A chain attaches to a service under `listener.chain` for reverse handlers (`rtcp`/`rudp`) or `handler.chain` for forward-proxy handlers (`tcp`/`socks5`/`http`/`relay`) — GOST's own distinction, not a panel convention.

The handler/transport type lists (`GOST_HANDLER_TYPES` / `GOST_TRANSPORT_TYPES` in `core/gost/core.sh`) are the single source of truth read generically by the prompt code — adding a new handler or transport GOST supports is a one-line addition, not a redesign.

## Advantages

- The only engine here that can express a multi-hop chain (e.g. relay through an intermediate node with a different protocol per hop).
- Handles reverse proxy, forward proxy, and port-forward topologies from one binary — genuinely flexible where the other five engines assume one fixed topology.
- Protocol chaining plus per-hop transport choice gives real DPI-evasion combinations (e.g. `relay` over `wss`) that a fixed two-node tunnel can't.

## Disadvantages

- Steepest learning curve of any engine here — chains and handler/listener/forwarder composition are a different mental model than "server, client, ports."
- Single shared `gost.yaml`/`gost.service` model means one panel-level config to keep coherent, rather than independent per-tunnel files.
- Overkill for a plain two-server port forward — if that's all you need, Backhaul or Rathole get there with far fewer decisions.

## Performance

Comparable to other Go-based proxy tools for straightforward TCP/HTTP forwarding; actual throughput depends heavily on which handler/transport combination and how many chain hops you configure — a direct `tcp` service will always outperform a multi-hop chain through `relay`+`wss`.

## Security

Whatever the chosen transport provides: `tls`/`wss`/`quic`/`grpc`/`h2` all carry real TLS; `tcp`/`kcp` don't. Chaining through an intermediate hop can also be a deliberate security/anonymity choice, not just an obfuscation one — GOST is the only engine here where that's expressible at all.

## Best use cases

- You need a topology none of the other five engines can express (multi-hop, mixed protocols per hop, or forward-proxy + reverse-tunnel from the same binary).
- You're already comfortable with GOST's upstream concepts and want the panel to manage the systemd/install/backup lifecycle around it.

## When not to use it

- A plain two-server tunnel is all you need — the other engines get there with a fraction of the decisions.
- You want per-tunnel independent config files (edit one without touching others) — GOST's shared-config model doesn't work that way.

## Recommended configuration

Start with **Quick Start** (a simple TCP/UDP forward wizard) for the common case. Reach for **Services (advanced)** and **Chains** only when you specifically need protocol chaining or a topology Quick Start can't express.

## Menu path

**5) GOST Manager** → Quick Start (simple TCP/UDP forward) / Services (advanced) / Chains (protocol/transport chaining) / Diagnostics / View logs / Restart gost.

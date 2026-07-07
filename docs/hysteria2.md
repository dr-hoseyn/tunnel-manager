# Hysteria2

## What it is

Hysteria2 ([apernet/hysteria](https://github.com/apernet/hysteria)) is a QUIC-based (UDP) proxy protocol built specifically for links with heavy packet loss, active throttling, or DPI interference — its congestion control is tuned for exactly those conditions, not for clean-link raw throughput.

## How it works

IRAN runs the server (listens on a UDP port, self-signed TLS cert, shared password auth), KHAREJ runs the client (dials out, forwards local ports through the tunnel). Unlike Backhaul/Rathole/FRP, the forwarded-port config (`tcpForwarding`) lives on the **client** (KHAREJ) side, not the server — that's Hysteria2's own design, not a panel convention: the client listens locally, and `remote` is an address reachable from the server's (IRAN's) network.

Optional **Salamander obfuscation** wraps the QUIC handshake itself, hiding the protocol fingerprint from DPI that specifically looks for QUIC/Hysteria2 patterns — this panel defaults it to **on** for new tunnels.

## Advantages

- Congestion control designed for loss/latency, not just raw bandwidth — meaningfully better than TCP-based tunnels on a degraded link.
- QUIC runs over UDP, which many DPI/throttling systems handle less aggressively than they handle recognizable TCP tunnel patterns.
- Salamander obfuscation adds a second layer of resistance specifically against DPI that *does* fingerprint QUIC/Hysteria2.
- Genuinely popular in exactly the censorship-circumvention niche this panel's IRAN/KHAREJ split is built for.

## Disadvantages

- UDP-only — some networks/providers filter or rate-limit UDP more aggressively than TCP, which would hurt Hysteria2 specifically.
- No certificate validation between the two sides in this panel's setup (see [Security](#security)) — same trust model as every other engine here, but worth knowing explicitly since Hysteria2 is TLS-based where Backhaul/Rathole/FRP mostly aren't.
- This panel only exposes TCP forwarding, not Hysteria2's SOCKS5/HTTP proxy modes or UDP forwarding — if you need those, you'd configure them by hand outside the panel.

## Performance

Strong on lossy/high-latency/throttled links specifically because of its congestion control; on a clean, unfiltered link, Backhaul's plain TCP transport will generally still edge it out on raw throughput. Obfuscation (Salamander) has a small CPU/latency cost — worth it if the link is actually filtered, unnecessary overhead if it isn't.

## Security

- Auth is a shared password (`auth.password`), matched on both sides.
- TLS uses the panel's shared self-signed cert on the server; the client sets `insecure: true` rather than validating it, because Iran and Kharej are separate servers with separate panel installs — there's no in-panel channel to move a cert fingerprint from one to the other. The real trust boundary is the password (and the obfuscation password, if enabled), not certificate identity.
- Obfuscation password is separate from the auth password and optional — enabled by default for new tunnels in this panel, since DPI resistance is Hysteria2's whole point.

## Best use cases

- The link between IRAN and KHAREJ is actively throttled, has DPI targeting recognizable tunnel protocols, or has meaningful packet loss.
- You've tried a TCP-based engine (Backhaul, Rathole, FRP) on this specific link and it's underperforming or getting reset.

## When not to use it

- The link is clean and unfiltered — a TCP engine will likely give better raw throughput with less overhead.
- The network path specifically filters/deprioritizes UDP — Hysteria2 needs UDP to work at all.

## Recommended configuration

Keep obfuscation on unless you've confirmed the link doesn't need it. Set a realistic-looking SNI (the panel defaults to a plausible domain) rather than leaving it blank, for an extra layer of traffic-shape camouflage.

## Menu path

**6) Hysteria2** → its own submenu: Configure a new tunnel / Tunnel management / Check tunnel status / Update Hysteria2 core.

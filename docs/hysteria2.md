# Hysteria2

## What it is

Hysteria2 ([apernet/hysteria](https://github.com/apernet/hysteria)) is a QUIC/UDP proxy designed for links with packet loss, throttling, or DPI interference.

## Reverse-tunnel direction

For this panel's reverse-tunnel use case, **KHAREJ runs the Hysteria2 server** and **IRAN runs the client**. Hysteria2's `tcpForwarding.listen` exists on the client, so putting the client on IRAN exposes the public ports where users need them. The KHAREJ server then connects `remote` to the local backend.

This direction is intentionally different from Backhaul, Rathole, and FRP.

## Advantages

- Congestion control designed for lossy and high-latency links.
- QUIC/UDP can behave better than TCP tunnels on some filtered paths.
- Optional Salamander obfuscation hides the Hysteria2 QUIC handshake pattern; the panel enables it by default for new tunnels.

## Disadvantages

- UDP-only; paths that block or heavily deprioritize UDP will not work well.
- The SHA-256 certificate fingerprint printed on KHAREJ must be copied into the IRAN setup prompt.
- The panel currently exposes TCP forwarding, not every Hysteria2 proxy/forwarding mode.

## Security

- Both sides use the same authentication password. Salamander has a separate optional password.
- KHAREJ uses the panel's self-signed certificate. IRAN sets `insecure: true` only to bypass public-CA validation and also requires `pinSHA256`, so the exact server certificate is still authenticated and a MITM cannot simply steal the password.
- Manual certificate renewal changes the fingerprint. Update the pin on IRAN before restarting the tunnel.

## Recommended use

Use Hysteria2 when TCP tunnels are throttled/reset or the path has meaningful loss. Keep Salamander enabled unless testing proves it unnecessary. Confirm UDP is allowed in both the OS and provider firewall.

## Setup order

1. Configure **KHAREJ (Server / backend side)** and copy the printed SHA-256 fingerprint.
2. Configure **IRAN (Client / public forwarded ports)** with the KHAREJ address, matching passwords, and that exact fingerprint.

Menu: **6) Hysteria2**.

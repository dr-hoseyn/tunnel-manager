# TUIC

## What it is

TUIC is a QUIC/UDP tunnel in the same broad niche as Hysteria2. The panel installs the actively maintained [`Itsusinn/tuic`](https://github.com/Itsusinn/tuic) implementation, which publishes separate server and client binaries.

## Reverse-tunnel direction

For reverse tunneling, **KHAREJ runs the TUIC server** (`[users]`) and **IRAN runs the client** (`[relay]`). TUIC's `[[local.tcp_forward]]` listener exists on the client, so this direction exposes public ports on IRAN while KHAREJ reaches the local backend.

## Advantages

- QUIC/UDP is worth testing when TCP tunnels are degraded.
- UUID+password authentication.
- Lightweight alternative to Hysteria2 on some links.

## Disadvantages

- UDP-only and a smaller ecosystem than Hysteria2 or FRP.
- The KHAREJ certificate must be securely copied to a separate file on IRAN before configuring the client.
- Upstream config/release formats can evolve; back up before core upgrades.

## Security

- The UUID and password must match on both sides.
- KHAREJ uses the panel's self-signed certificate. IRAN loads the copied certificate through `relay.certificates` and keeps `skip_cert_verify = false`. The default SNI `backhaul.com` matches the panel-generated certificate.
- Downloads are fail-closed. The panel verifies an upstream checksum file when available, otherwise GitHub's SHA-256 release-asset digest. A missing or mismatched digest aborts installation.
- Manual certificate renewal requires copying the new certificate to IRAN before restarting TUIC.

## Setup order

1. Configure **KHAREJ (Server / backend side)**.
2. Secure-copy the displayed certificate path to a separate file on IRAN.
3. Configure **IRAN (Client / public forwarded ports)** with the matching UUID/password, `backhaul.com` SNI, and the copied certificate path.

Menu: **8) TUIC**.

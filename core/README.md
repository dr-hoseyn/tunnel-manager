# Tunnel core plugin interface

Every tunnel engine (Backhaul, Rathole, GOST, Hysteria2, FRP, TUIC, ...) lives
in its own `core/<name>/core.sh` and is sourced once by `tunnel-manager.sh`.
Adding a new engine means writing one new file and wiring four call sites —
the rest of the app (menu shell, watchdog timer, uninstall) never changes.

## Required boundary (every core must expose these)

These are the only functions `tunnel-manager.sh` and the cross-core
dispatchers call directly. Everything else inside a core is private to it.

| Function | Called from | Contract |
|---|---|---|
| `core_<name>_ensure_ready` | Before the core's menu opens (or eagerly at startup, see below) | Installs the engine's binary if missing, runs any one-time repair checks. Must be cheap/idempotent to call repeatedly. |
| `core_<name>_menu` | `read_option()` in `tunnel-manager.sh` | Owns the engine's own submenu loop (`while true; do ... done`, returns on `0`). Calls `core_<name>_ensure_ready` itself on entry. |
| `core_<name>_destroy_all` | `uninstall_everything()` | Removes every tunnel this core has configured (services + configs + firewall rules it added), silently (no prompts — the confirmation already happened once at the top of `uninstall_everything`). |
| `core_<name>_watchdog_check_all` | `run_watchdog_check()` (cron/timer path, `--watchdog` flag) | Restarts any of the core's services that should be running but aren't. No output beyond `logger`. |

`Backhaul` is the one exception to `core_<name>_menu`: its three primary
actions (`core_backhaul_configure`, `core_backhaul_manage`,
`core_backhaul_status`) are wired directly into the top-level menu instead of
behind a `core_backhaul_menu` submenu. That's deliberate, not an oversight —
Backhaul is the original, highest-traffic workflow, and putting it behind an
extra menu layer would cost every user an extra keypress for the single most
common action. New cores should still use `core_<name>_menu` as shown above;
Backhaul just also happens to expose its three functions at the top level in
addition.

## Common internal shape (not enforced, but follow it)

Within a core, `core/rathole/core.sh`, `core/hysteria2/core.sh`,
`core/frp/core.sh`, and `core/tuic/core.sh` are the reference implementations
to copy from — each was written by mirroring the previous one
function-for-function. All four follow this shape:

- `core_<name>_configure(mode, existing_config)` — prompts for a new tunnel,
  or (when `existing_config` is passed) prefills every prompt's default from
  the current value so pressing Enter never resets a field.
- `core_<name>_generate_*_config` — pure config-file writers, no prompting.
- `core_<name>_create_service` — writes + enables the systemd unit.
- `core_<name>_diagnostics` / `core_<name>_benchmark` — reachability and
  throughput checks, using the shared probes in `lib/common.sh`
  (`tcp_port_open`, `ping_stats`, `benchmark_tcp_probe`, etc.) rather than
  reimplementing them.
- `core_<name>_edit` — backs up (`backup_tunnel`), re-runs `configure`, rolls
  back (`restore_tunnel_backup`) if the service doesn't come back healthy.
- `core_<name>_destroy` — removes one tunnel; takes an optional `--silent`
  flag so `destroy_all` can call it without prompting.
- `core_<name>_detail_page` / `core_<name>_tunnel_management` /
  `core_<name>_check_status` — the list/detail UI.

Shared, cross-core helpers (`write_tunnel_meta`, `read_tunnel_meta`,
`write_tunnel_last_test`, `read_tunnel_last_test`, `ensure_watchdog_installed`,
`toggle_tunnel_enabled`, `parse_port_entry`) live in `core/backhaul/core.sh`
today because that's the first core that needed them and every other core is
sourced after it — not because they're Backhaul-specific. Rathole, Hysteria2,
FRP, and TUIC all already depend on this. Give tunnel identities a `<name>-`
prefix (`rathole-iran2333`, `hysteria2-iran36712`, `frp-iran7000`,
`tuic-iran44300`) when calling these so they never collide with a
same-numbered Backhaul tunnel.

Each core also picks its own config format/tooling depending on what the
upstream engine actually speaks and what's verifiable against real upstream
docs/source — don't force a common format:

| Core | Config format | Getter strategy |
|---|---|---|
| Backhaul, Rathole, FRP, TUIC | TOML (bracketed `[section]` tables) | Shared `toml_get()` in `lib/common.sh` for scalars; hand-written awk getters for any array-of-tables (FRP's `[[proxies]]`, TUIC's `[[local.tcp_forward]]`) |
| Hysteria2 | YAML | No shared YAML parser exists — small grep/sed getters that only work because the generator emits a fixed, hand-controlled shape (see the file-header note in `core/hysteria2/core.sh`) |

Port-forwarding direction also varies by engine, not by convention — follow
what each upstream tool actually does rather than forcing IRAN/KHAREJ
symmetry: Backhaul/Rathole/FRP put the forwarded-port config on the SERVER
(IRAN) side; Hysteria2/TUIC put it on the CLIENT (KHAREJ) side, because
that's where each protocol's own local-forward feature lives.

## Checklist for adding a new core

1. `core/<name>/core.sh` implementing the boundary above.
2. Source it in `tunnel-manager.sh` (one `source` line, after the existing ones).
3. Add it to `run_watchdog_check()`.
4. Add it to `uninstall_everything()` (both the `destroy_all` call and the
   description text near the top).
5. Give it a numbered entry in `display_menu()` / `read_option()`.
6. `install.sh` needs no changes — it copies `core/` recursively.

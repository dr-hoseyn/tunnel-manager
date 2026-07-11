#!/usr/bin/env bash
# Main entrypoint. Sources the shared library and every tunnel core, then
# drives the top-level menu. Backhaul's own items (1-3) are wired directly to
# its functions, unchanged in position/numbering/behavior from the
# pre-refactor script. Adding a new core (FRP, TUIC, ...) means writing
# core/<name>/core.sh and wiring it in four places — see core/README.md for
# the full plugin interface contract and a step-by-step checklist.
SCRIPT_VERSION="v2.0.0"
SCRIPT_MODE="$1"
INSTALL_DIR="/opt/tunnel-manager"
PANEL_PATH="/usr/local/bin/backhaul"
TUNNEL_MANAGER_PATH="/usr/local/bin/tunnel-manager"
service_dir="/etc/systemd/system"
config_dir="/root/backhaul-core"
CERT_DIR="${config_dir}/cert_files"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/cert.key"
mkdir -p "$CERT_DIR"

if [[ $EUID -ne 0 ]]; then
echo "This script must be run as root"
sleep 1
exit 1
fi

# Sourced by absolute install path rather than resolving our own location via
# BASH_SOURCE: /usr/local/bin/backhaul is a tiny wrapper (`exec` into this
# script), and BASH_SOURCE reports the wrapper's own path, not this file's —
# resolving lib/core relative to that would look in /usr/local/bin and miss.
# shellcheck source=lib/common.sh
source "${INSTALL_DIR}/lib/common.sh"
# shellcheck source=lib/network_tune.sh
source "${INSTALL_DIR}/lib/network_tune.sh"
# shellcheck source=core/backhaul/core.sh
source "${INSTALL_DIR}/core/backhaul/core.sh"
# shellcheck source=core/rathole/core.sh
source "${INSTALL_DIR}/core/rathole/core.sh"
# shellcheck source=core/gost/core.sh
source "${INSTALL_DIR}/core/gost/core.sh"
# shellcheck source=core/hysteria2/core.sh
source "${INSTALL_DIR}/core/hysteria2/core.sh"
# shellcheck source=core/frp/core.sh
source "${INSTALL_DIR}/core/frp/core.sh"
# shellcheck source=core/tuic/core.sh
source "${INSTALL_DIR}/core/tuic/core.sh"

emit_metrics_json() {
local hostname cpu mem_used mem_total mem_pct iface rx tx
hostname=$(hostname)
cpu=$(cpu_usage_percent)
read -r mem_used mem_total mem_pct <<< "$(mem_usage_info)"
iface=$(detect_default_interface)
read -r rx tx <<< "$(net_rate_kbps "$iface")"
printf '{"hostname":"%s","cpu_percent":"%s","memory":{"used_mb":"%s","total_mb":"%s","percent":"%s"},"network":{"interface":"%s","rx_kbps":"%s","tx_kbps":"%s"},"timestamp":"%s"}\n' \
"$(json_escape "$hostname")" "$cpu" "$mem_used" "$mem_total" "$mem_pct" "$(json_escape "$iface")" "$rx" "$tx" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

emit_status_json() {
local hostname gost_active gost_entities
hostname=$(hostname)
if systemctl is-active --quiet "$GOST_SERVICE_NAME" 2>/dev/null; then gost_active="true"; else gost_active="false"; fi
gost_entities=$(( $(core_gost_list_services | grep -c .) + $(core_gost_list_chains | grep -c .) ))
local -a lines=()
mapfile -t lines < <(
emit_engine_tunnels_json "$config_dir" "backhaul" "backhaul" "toml"
emit_engine_tunnels_json "$RATHOLE_DIR" "rathole" "rathole" "toml"
emit_engine_tunnels_json "$HYSTERIA2_DIR" "hysteria2" "hysteria2" "yaml"
emit_engine_tunnels_json "$FRP_DIR" "frp" "frp" "toml"
emit_engine_tunnels_json "$TUIC_DIR" "tuic" "tuic" "toml"
)
local joined
joined=$(IFS=,; echo "${lines[*]}")
printf '{"hostname":"%s","tunnels":[%s],"gost":{"active":%s,"entities":%d}}\n' \
"$(json_escape "$hostname")" "$joined" "$gost_active" "$gost_entities"
}

# --list-json/--metrics-json are the machine-readable interface a remote
# Agent shells out to (see tunnel-panel/agent) — kept deliberately fast and
# side-effect-free: no network IP-detection calls, no core-install checks,
# nothing interactive. Checked before any of that startup work runs, not
# after, specifically so polling this every few seconds stays cheap.
if [[ "$SCRIPT_MODE" == "--list-json" ]]; then
emit_status_json
exit 0
fi
if [[ "$SCRIPT_MODE" == "--metrics-json" ]]; then
emit_metrics_json
exit 0
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
SERVER_COUNTRY=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.country' 2>/dev/null)
SERVER_ISP=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.isp' 2>/dev/null)
# Detected once at startup and reused as prompt defaults (e.g. "Kharej Server
# IP") so users aren't stuck typing their own public address every time.
PUBLIC_IPV4=$(detect_public_ipv4)
PUBLIC_IPV6=$(detect_public_ipv6)

# Matches the pre-refactor script's own startup sequence exactly (it ran
# these three unconditionally before ever showing a menu). Kept eager here
# for the same reason: Backhaul is the original, primary workflow and its
# existing behavior — including this startup check — must not change.
# Rathole/GOST stay lazy (core_rathole_ensure_ready / core_gost_ensure_ready
# only run when their own menu is opened) since, unlike backhaul_premium,
# install.sh doesn't pre-provision their binaries; there's nothing to be
# eager about and no prior behavior to preserve.
core_backhaul_ensure_ready

# Only Hysteria2/TUIC servers always use the shared self-signed cert;
# Backhaul only does for server-mode tunnels on wss/anytls/wssmux transports,
# and only when the user kept the default cert path (a customized path means
# it isn't ours to rotate, so it's deliberately left alone). Checked on every
# watchdog run (every 5 minutes via the timer) so renewal happens well before
# the 365-day cert actually expires, not just whenever someone next opens the
# panel to configure or edit a tunnel.
watchdog_renew_shared_cert() {
ensure_cert_fresh "$CERT_FILE" "$KEY_FILE" || return 0
logger -t cert-renewal "Shared self-signed cert renewed, restarting dependent services" 2>/dev/null
local f
for f in "${config_dir}"/iran*.toml; do
[[ -f "$f" ]] || continue
[[ "$(toml_get "$f" "tls" "tls_cert")" == "$CERT_FILE" ]] && systemctl restart "backhaul-$(basename "${f%.toml}").service" 2>/dev/null
done
for f in "${HYSTERIA2_DIR}"/iran*.yaml; do
[[ -f "$f" ]] || continue
systemctl restart "hysteria2-$(basename "${f%.yaml}").service" 2>/dev/null
done
for f in "${TUIC_DIR}"/iran*.toml; do
[[ -f "$f" ]] || continue
systemctl restart "tuic-$(basename "${f%.toml}").service" 2>/dev/null
done
}

run_watchdog_check() {
core_backhaul_watchdog_check_all
core_rathole_watchdog_check_all
core_gost_watchdog_check
core_hysteria2_watchdog_check_all
core_frp_watchdog_check_all
core_tuic_watchdog_check_all
watchdog_renew_shared_cert
}

uninstall_everything() {
clear
colorize red "═══════════════════════════════════════" bold
colorize red "  FULL UNINSTALL — THIS IS DESTRUCTIVE" bold
colorize red "═══════════════════════════════════════" bold
echo ""
echo "This will:"
echo "  - Stop and remove every configured tunnel (Backhaul, Rathole, GOST, Hysteria2, FRP, TUIC) and their firewall/forwarding rules"
echo "  - Remove the watchdog timer"
echo "  - Remove the journald size-limit and sysctl (ip_forward/rp_filter) drop-ins"
echo "  - Remove the network-optimize sysctl/module-load/systemd drop-ins, if applied"
echo "  - Remove any HAProxy/IPVS/Fail2Ban config this panel created (not the packages themselves)"
echo "  - Delete ${config_dir} (all configs, certs, backups, both cores' binaries)"
echo "  - Delete this panel (${INSTALL_DIR}, ${PANEL_PATH}, ${TUNNEL_MANAGER_PATH})"
echo ""
colorize yellow "This cannot be undone."
echo ""
local confirm
read -r -p "Type UNINSTALL (all caps) to proceed, anything else to cancel: " confirm
if [[ "$confirm" != "UNINSTALL" ]]; then
colorize yellow "Cancelled."
press_key
return
fi
echo ""
colorize yellow "Removing all Backhaul tunnels..."
core_backhaul_destroy_all
colorize yellow "Removing all Rathole tunnels..."
core_rathole_destroy_all
colorize yellow "Removing GOST..."
core_gost_destroy_all
colorize yellow "Removing all Hysteria2 tunnels..."
core_hysteria2_destroy_all
colorize yellow "Removing all FRP tunnels..."
core_frp_destroy_all
colorize yellow "Removing all TUIC tunnels..."
core_tuic_destroy_all
colorize yellow "Removing watchdog timer..."
systemctl disable --now backhaul-watchdog.timer >/dev/null 2>&1
rm -f "${service_dir}/backhaul-watchdog.timer" "${service_dir}/backhaul-watchdog.service"
systemctl daemon-reload
colorize yellow "Removing Fail2Ban SSH jail (if this panel created one)..."
[[ -f "$FAIL2BAN_JAIL_FILE" ]] && disable_fail2ban_ssh_protection >/dev/null 2>&1
colorize yellow "Removing journald and sysctl drop-ins..."
rm -f /etc/systemd/journald.conf.d/backhaul-tunnel.conf
systemctl restart systemd-journald >/dev/null 2>&1
rm -f /etc/sysctl.d/99-backhaul-tunnel.conf
rm -f /etc/modules-load.d/backhaul-tunnel.conf
if core_optimize_is_applied || [[ -f "$NETTUNE_BBR_MODULE_CONF" ]]; then
colorize yellow "Rolling back network optimization..."
core_optimize_rollback >/dev/null 2>&1
fi
colorize yellow "Removing config directory..."
rm -rf "$config_dir"
colorize green "✔ Everything removed."
sleep 1
colorize yellow "Deleting this panel..."
rm -f "$PANEL_PATH" "$TUNNEL_MANAGER_PATH"
rm -rf "$INSTALL_DIR"
echo ""
colorize green "Done. Goodbye."
exit 0
}

# Sampling (cpu_usage_percent + net_rate_kbps) blocks for ~1.3s per refresh
# by design — this reads /proc directly rather than running a background
# daemon, which is the right tradeoff for a terminal panel but means this
# is refresh-every-few-seconds, not truly real-time.
dashboard_view() {
while true; do
clear
colorize cyan "Live Dashboard" bold
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""
local cpu mem_used mem_total mem_pct
cpu=$(cpu_usage_percent)
read -r mem_used mem_total mem_pct <<< "$(mem_usage_info)"
echo -e "\033[36mCPU:\033[0m ${cpu}%"
echo -e "\033[36mRAM:\033[0m ${mem_used}MB / ${mem_total}MB (${mem_pct}%)"
local iface rx tx
iface=$(detect_default_interface)
if [[ -n "$iface" ]]; then
read -r rx tx <<< "$(net_rate_kbps "$iface")"
echo -e "\033[36mNetwork (${iface}):\033[0m down ${rx} KB/s / up ${tx} KB/s"
fi
echo ""
colorize blue "── Tunnels ──" bold
local a t
read -r a t <<< "$(count_tunnels_multi "$config_dir" "backhaul" "toml")"
echo "Backhaul:  ${a}/${t} active"
read -r a t <<< "$(count_tunnels_multi "$RATHOLE_DIR" "rathole" "toml")"
echo "Rathole:   ${a}/${t} active"
read -r a t <<< "$(count_tunnels_multi "$HYSTERIA2_DIR" "hysteria2" "yaml")"
echo "Hysteria2: ${a}/${t} active"
read -r a t <<< "$(count_tunnels_multi "$FRP_DIR" "frp" "toml")"
echo "FRP:       ${a}/${t} active"
read -r a t <<< "$(count_tunnels_multi "$TUIC_DIR" "tuic" "toml")"
echo "TUIC:      ${a}/${t} active"
local gost_status gost_entities
if systemctl is-active --quiet "$GOST_SERVICE_NAME" 2>/dev/null; then gost_status="active"; else gost_status="inactive"; fi
gost_entities=$(( $(core_gost_list_services | grep -c .) + $(core_gost_list_chains | grep -c .) ))
echo "GOST:      ${gost_status} (${gost_entities} services+chains configured)"
echo ""
echo "Auto-refreshing every 5s — press 0 to go back"
local key
read -r -t 5 -n 1 -s key
[[ "$key" == "0" ]] && return
done
}

security_maintenance_menu() {
while true; do
clear
colorize cyan "Security & Maintenance" bold
echo ""
if [[ -f "$CERT_FILE" ]]; then
local cert_days
cert_days=$(cert_days_remaining "$CERT_FILE")
echo "TLS Certificate: valid for ${cert_days} more days (auto-renews via watchdog inside 30 days of expiry)"
else
echo "TLS Certificate: not generated yet (created automatically the first time a tunnel needs one)"
fi
echo "Fail2Ban SSH protection: $(fail2ban_ssh_status)"
echo ""
colorize green " 1. Renew TLS certificate now" bold
colorize green " 2. Enable Fail2Ban SSH protection" bold
colorize red " 3. Disable Fail2Ban SSH protection" bold
echo " 0. Back"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Enter your choice [0-3]: " choice
case "$choice" in
1)
rm -f "$CERT_FILE" "$KEY_FILE"
ensure_cert_fresh "$CERT_FILE" "$KEY_FILE"
colorize yellow "Restart any TLS-using tunnels (Backhaul wss/anytls/wssmux, Hysteria2, TUIC) to pick up the new cert — or wait for the next watchdog cycle."
press_key
;;
2) enable_fail2ban_ssh_protection; press_key ;;
3) disable_fail2ban_ssh_protection; press_key ;;
0) return ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
done
}

network_optimize_menu() {
while true; do
clear
colorize cyan "Optimize Network" bold
echo ""
if core_optimize_is_applied; then
echo "Status: applied"
echo "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
else
echo "Status: not applied"
fi
echo ""
echo "Tunes buffers/backlog/conntrack, enables BBR+fq where supported, and"
echo "reserves this box's currently-listening ports out of the ephemeral"
echo "port range so they never collide with it."
echo ""
colorize green " 1. Apply / re-apply optimization" bold
colorize red " 2. Roll back" bold
echo " 0. Back"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Enter your choice [0-2]: " choice
case "$choice" in
1) core_optimize_apply; press_key ;;
2) core_optimize_rollback; press_key ;;
0) return ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
done
}

update_script() {
colorize yellow "Updating Tunnel Manager..."
local tmp_dir
tmp_dir=$(mktemp -d)
if ! curl -fsSL "https://github.com/dr-hoseyn/tunnel-manager/archive/refs/heads/main.tar.gz" -o "${tmp_dir}/src.tar.gz"; then
colorize red "✘ Download failed."
rm -rf "$tmp_dir"
press_key
return 1
fi
tar -xzf "${tmp_dir}/src.tar.gz" -C "$tmp_dir"
local extracted
extracted=$(find "$tmp_dir" -maxdepth 1 -type d -name "tunnel-manager-*" | head -1)
if [[ -z "$extracted" ]]; then
colorize red "✘ Unexpected archive layout."
rm -rf "$tmp_dir"
press_key
return 1
fi
local tmp_install
tmp_install=$(mktemp -d "$(dirname "$INSTALL_DIR")/.tunnel-manager.XXXXXX")
cp -r "${extracted}/lib" "${extracted}/core" "${extracted}/tunnel-manager.sh" "$tmp_install/"
chmod +x "${tmp_install}/tunnel-manager.sh"
rm -rf "$INSTALL_DIR"
mv -f "$tmp_install" "$INSTALL_DIR"
rm -rf "$tmp_dir"
colorize green "✔ Updated. Restarting..."
sleep 1
exec "${PANEL_PATH}"
}

display_menu() {
clear
display_logo
display_server_info
display_backhaul_core_status
echo
colorize green " 1. Configure a new tunnel" bold
colorize red " 2. Tunnel management" bold
colorize cyan " 3. Check tunnel status" bold
echo "──────────────────────────────────"
colorize green " 4. Rathole" bold
colorize magenta " 5. GOST Manager" bold
colorize yellow " 6. Hysteria2 (QUIC, DPI/throttling resistant)" bold
colorize blue " 7. FRP" bold
colorize magenta " 8. TUIC (QUIC, lightweight alternative)" bold
echo "──────────────────────────────────"
colorize green " 9. Dashboard (live CPU/RAM/network + tunnel status)" bold
colorize blue "10. Security & Maintenance (TLS cert, Fail2Ban)" bold
colorize blue "11. Optimize Network (BBR, buffers, conntrack, port reservation)" bold
echo "──────────────────────────────────"
echo "12. Update Backhaul Core"
echo "13. Update script"
echo "14. Remove Backhaul Core"
colorize red "15. Uninstall everything" bold
echo " 0. Exit"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

read_option() {
read -r -p "Enter your choice [0-15]: " choice
case $choice in
1) core_backhaul_configure ;;
2) core_backhaul_manage ;;
3) core_backhaul_status ;;
4) core_rathole_menu ;;
5) core_gost_menu ;;
6) core_hysteria2_menu ;;
7) core_frp_menu ;;
8) core_tuic_menu ;;
9) dashboard_view ;;
10) security_maintenance_menu ;;
11) network_optimize_menu ;;
12) core_backhaul_ensure_ready; download_and_extract_backhaul "menu" ;;
13) update_script ;;
14) remove_core ;;
15) uninstall_everything ;;
0) exit 0 ;;
*) colorize red "Invalid option!" && sleep 1 ;;
esac
}

if [[ "$SCRIPT_MODE" == "--watchdog" ]]; then
run_watchdog_check
exit 0
fi
while true; do
display_menu
read_option
done

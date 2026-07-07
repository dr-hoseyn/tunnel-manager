#!/usr/bin/env bash
# Main entrypoint. Sources the shared library and every tunnel core, then
# drives the top-level menu. Adding a new core (frp, hysteria, tuic, ...)
# means writing core/<name>/core.sh with the same core_<name>_* functions
# used below (ensure_ready, configure_tunnel/menu, destroy_all,
# watchdog_check_all) and adding it to tunnel_manager_menu() and the
# cross-core dispatchers (run_watchdog_check, uninstall_everything) — the
# rest of the app does not need to change.
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
# shellcheck source=core/backhaul/core.sh
source "${INSTALL_DIR}/core/backhaul/core.sh"
# shellcheck source=core/rathole/core.sh
source "${INSTALL_DIR}/core/rathole/core.sh"
# shellcheck source=core/gost/core.sh
source "${INSTALL_DIR}/core/gost/core.sh"

SERVER_IP=$(hostname -I | awk '{print $1}')
SERVER_COUNTRY=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.country' 2>/dev/null)
SERVER_ISP=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.isp' 2>/dev/null)

backhaul_menu() {
core_backhaul_ensure_ready
while true; do
clear
colorize cyan "Backhaul" bold
echo ""
colorize green " 1. Configure a new tunnel" bold
colorize red " 2. Tunnel management" bold
colorize cyan " 3. Check tunnel status" bold
echo " 0. Back"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Enter your choice [0-3]: " choice
case "$choice" in
1) configure_tunnel ;;
2) tunnel_management ;;
3) check_tunnel_status ;;
0) return ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
done
}

tunnel_manager_menu() {
while true; do
clear
colorize cyan "Tunnel Manager" bold
echo ""
colorize green " 1. Backhaul" bold
colorize green " 2. Rathole" bold
echo " 0. Back"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Enter your choice [0-2]: " choice
case "$choice" in
1) backhaul_menu ;;
2) core_rathole_menu ;;
0) return ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
done
}

check_all_tunnel_status() {
check_tunnel_status
core_rathole_check_status
}

run_watchdog_check() {
core_backhaul_watchdog_check_all
core_rathole_watchdog_check_all
core_gost_watchdog_check
}

uninstall_everything() {
clear
colorize red "═══════════════════════════════════════" bold
colorize red "  FULL UNINSTALL — THIS IS DESTRUCTIVE" bold
colorize red "═══════════════════════════════════════" bold
echo ""
echo "This will:"
echo "  - Stop and remove every configured tunnel (Backhaul, Rathole, GOST) and their firewall/forwarding rules"
echo "  - Remove the watchdog timer"
echo "  - Remove the journald size-limit and sysctl (ip_forward/rp_filter) drop-ins"
echo "  - Remove any HAProxy/IPVS config this panel created (not the packages themselves)"
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
colorize yellow "Removing watchdog timer..."
systemctl disable --now backhaul-watchdog.timer >/dev/null 2>&1
rm -f "${service_dir}/backhaul-watchdog.timer" "${service_dir}/backhaul-watchdog.service"
systemctl daemon-reload
colorize yellow "Removing journald and sysctl drop-ins..."
rm -f /etc/systemd/journald.conf.d/backhaul-tunnel.conf
systemctl restart systemd-journald >/dev/null 2>&1
rm -f /etc/sysctl.d/99-backhaul-tunnel.conf
rm -f /etc/modules-load.d/backhaul-tunnel.conf
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
colorize green " 1. Tunnel Manager (Backhaul / Rathole)" bold
colorize magenta " 2. GOST Manager" bold
colorize cyan " 3. Check tunnel status" bold
echo " 4. Update Backhaul Core"
echo " 5. Update script"
echo " 6. Remove Backhaul Core"
colorize red " 7. Uninstall everything" bold
echo " 0. Exit"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

read_option() {
read -r -p "Enter your choice [0-7]: " choice
case $choice in
1) tunnel_manager_menu ;;
2) core_gost_menu ;;
3) check_all_tunnel_status ;;
4) core_backhaul_ensure_ready; download_and_extract_backhaul "menu" ;;
5) update_script ;;
6) remove_core ;;
7) uninstall_everything ;;
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

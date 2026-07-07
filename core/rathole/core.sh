#!/usr/bin/env bash
# Rathole tunnel core. Mirrors the Backhaul core's workflow (configure/edit/
# diagnostics/benchmark/backup/watchdog/uninstall) but generates rathole's own
# TOML dialect and manages its own binary/services, entirely separate from
# Backhaul's files. Requires lib/common.sh to already be sourced.
#
# Layout: ${config_dir}/rathole/rathole_bin, ${config_dir}/rathole/iranN.toml,
# ${config_dir}/rathole/kharejN.toml. Services: rathole-iranN.service /
# rathole-kharejN.service. Config identity for the shared meta/status/backup
# helpers is prefixed "rathole-" (e.g. "rathole-iran2333") so it never
# collides with a Backhaul tunnel that happens to use the same port number.
#
# Only the "tcp" transport is implemented today. rathole also supports "tls"
# and "noise" transports (see upstream docs/transport.md); the config
# generator below is written so adding them is a new case branch, not a
# rewrite — see core_rathole_generate_config.

RATHOLE_REPO="rathole-org/rathole"
RATHOLE_DIR="${config_dir}/rathole"
RATHOLE_BIN="${RATHOLE_DIR}/rathole_bin"

core_rathole_ensure_ready() {
mkdir -p "$RATHOLE_DIR"
core_rathole_install
}

core_rathole_install() {
[[ -f "$RATHOLE_BIN" ]] && return 0
mkdir -p "$RATHOLE_DIR"
colorize yellow "Installing Rathole..."
local arch asset
arch=$(uname -m)
case "$arch" in
x86_64) asset="rathole-x86_64-unknown-linux-gnu.zip" ;;
aarch64|arm64) asset="rathole-aarch64-unknown-linux-musl.zip" ;;
*)
colorize red "Unsupported architecture for Rathole: ${arch}."
press_key
return 1
;;
esac
if ! command -v unzip &> /dev/null && command -v apt-get &> /dev/null; then
apt-get update -qq >/dev/null 2>&1
apt-get install -y unzip >/dev/null 2>&1
fi
if ! command -v unzip &> /dev/null; then
colorize red "unzip is required to install Rathole but is not available."
press_key
return 1
fi
local latest_url tag
latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${RATHOLE_REPO}/releases/latest" 2>/dev/null)
tag="${latest_url##*/}"
if [[ -z "$tag" ]]; then
colorize red "Could not determine the latest Rathole release."
press_key
return 1
fi
local dl_url="https://github.com/${RATHOLE_REPO}/releases/download/${tag}/${asset}"
local tmp_dir
tmp_dir=$(mktemp -d)
if ! curl -fsSL "$dl_url" -o "${tmp_dir}/rathole.zip"; then
colorize red "Download failed: ${dl_url}"
rm -rf "$tmp_dir"
press_key
return 1
fi
unzip -o -q "${tmp_dir}/rathole.zip" -d "$tmp_dir"
if [[ ! -f "${tmp_dir}/rathole" ]]; then
colorize red "Downloaded archive did not contain the expected 'rathole' binary."
rm -rf "$tmp_dir"
press_key
return 1
fi
local tmp_bin
tmp_bin=$(mktemp "${RATHOLE_DIR}/.rathole_bin.XXXXXX")
cp "${tmp_dir}/rathole" "$tmp_bin"
chmod +x "$tmp_bin"
mv -f "$tmp_bin" "$RATHOLE_BIN"
rm -rf "$tmp_dir"
if ! "$RATHOLE_BIN" --help &> /dev/null; then
colorize red "Rathole binary failed a basic sanity check (--help)."
rm -f "$RATHOLE_BIN"
press_key
return 1
fi
colorize green "✔ Rathole ${tag} installed."
}

core_rathole_role() {
local file="$1"
if grep -q '^\[server\]$' "$file" 2>/dev/null; then
echo "server"
elif grep -q '^\[client\]$' "$file" 2>/dev/null; then
echo "client"
fi
}

core_rathole_config_name() {
local config_path="$1"
echo "rathole-$(basename "${config_path%.toml}")"
}

core_rathole_port_number() {
local file="$1" role="$2" addr
if [[ "$role" == "server" ]]; then
addr=$(toml_get "$file" "server" "bind_addr")
else
addr=$(toml_get "$file" "client" "remote_addr")
fi
echo "${addr##*:}"
}

core_rathole_suggest_free_port() {
local mode="$1" prefix port=2333
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
while [[ -f "${RATHOLE_DIR}/${prefix}${port}.toml" ]] || is_port_listening_system_wide "$port"; do
((port++))
done
echo "$port"
}

core_rathole_list_service_ports() {
local file="$1" role="$2" section
[[ "$role" == "server" ]] && section="server" || section="client"
awk -v prefix="[${section}.services." '
index($0, prefix) == 1 {
line = substr($0, length(prefix) + 1)
sub(/\].*/, "", line)
print line
}
' "$file" 2>/dev/null | sed -E 's/^svc//'
}

core_rathole_generate_config() {
local mode="$1" output_file="$2" ctrl_addr="$3" token="$4" ports_csv="$5"
local section
[[ "$mode" == "server" ]] && section="server" || section="client"
{
echo "[$section]"
if [[ "$mode" == "server" ]]; then
echo "bind_addr = \"${ctrl_addr}\""
else
echo "remote_addr = \"${ctrl_addr}\""
fi
echo "default_token = \"${token}\""
echo ""
# Transport defaults to plain tcp. To add tls/noise later: emit a
# "[${section}.transport]" block here based on a transport arg, following
# rathole's documented [client.transport]/[server.transport] format.
local -a ports=()
IFS=',' read -r -a ports <<< "$ports_csv"
local p
for p in "${ports[@]}"; do
p="${p// /}"
[[ -z "$p" ]] && continue
echo "[${section}.services.svc${p}]"
if [[ "$mode" == "server" ]]; then
echo "bind_addr = \"0.0.0.0:${p}\""
else
echo "local_addr = \"127.0.0.1:${p}\""
fi
echo ""
done
} > "$output_file"
}

core_rathole_create_service() {
local type="$1" port="$2" config_file="$3" mode="$4"
local flag
[[ "$mode" == "server" ]] && flag="-s" || flag="-c"
local service_file="${service_dir}/rathole-${type}${port}.service"
local desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"
cat > "$service_file" <<EOF
[Unit]
Description=Rathole $desc_type Port $port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${RATHOLE_BIN} ${flag} ${config_file}
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
IPAccounting=yes
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "rathole-${type}${port}.service" >/dev/null 2>&1
}

core_rathole_configure() {
local mode="$1"
local existing_config="$2"
local default_ctrl_addr="" default_token="" default_ports="" default_peer_ip="" default_peer_ssh_port="22"
local old_config_name=""
if [[ -n "$existing_config" && -f "$existing_config" ]]; then
local role
role=$(core_rathole_role "$existing_config")
if [[ "$mode" == "server" ]]; then
default_ctrl_addr=$(toml_get "$existing_config" "server" "bind_addr")
default_token=$(toml_get "$existing_config" "server" "default_token")
else
default_ctrl_addr=$(toml_get "$existing_config" "client" "remote_addr")
default_token=$(toml_get "$existing_config" "client" "default_token")
fi
default_ports=$(core_rathole_list_service_ports "$existing_config" "$role" | paste -sd, -)
old_config_name=$(core_rathole_config_name "$existing_config")
default_peer_ip=$(read_tunnel_meta "$old_config_name" "peer_ip")
default_peer_ssh_port=$(read_tunnel_meta "$old_config_name" "peer_ssh_port")
[[ -z "$default_peer_ssh_port" ]] && default_peer_ssh_port="22"
fi

clear
colorize cyan "Configuring Rathole $([[ "$mode" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")" bold
echo ""
local ctrl_addr token ports_csv peer_ip peer_ssh_port
if [[ "$mode" == "server" ]]; then
local suggested_port="${default_ctrl_addr#:}"
[[ -z "$suggested_port" ]] && suggested_port=$(core_rathole_suggest_free_port "server")
prompt_with_default "Bind Address" "$suggested_port" ctrl_addr
[[ -n "$ctrl_addr" && "$ctrl_addr" != *:* ]] && ctrl_addr=":${ctrl_addr}"
else
while true; do
prompt_with_default "IRAN Server Address [IP:Port]" "$default_ctrl_addr" ctrl_addr
[[ -n "$ctrl_addr" && "$ctrl_addr" == *:* ]] && break
colorize red "Invalid format. Use IP:Port."
done
fi
local generated_token
generated_token=$(head -c16 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c20)
prompt_with_default "Shared Token (must match on both sides)" "${default_token:-$generated_token}" token
echo ""
colorize green "Supported formats:"
echo "  1. 443           - forward port 443"
echo "  2. 443,8080      - forward multiple ports (comma-separated)"
echo ""
prompt_with_default "Ports to forward (comma-separated)" "$default_ports" ports_csv
if [[ -z "$ports_csv" ]]; then
colorize red "At least one port is required."
press_key
return 1
fi
echo ""
local peer_ip_default="$default_peer_ip"
if [[ "$mode" == "client" && -z "$peer_ip_default" ]]; then
peer_ip_default="${ctrl_addr%%:*}"
[[ "$peer_ip_default" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || peer_ip_default=""
fi
prompt_with_default "Peer Server IP (other side, optional, enables diagnostics)" "$peer_ip_default" peer_ip
if [[ -n "$peer_ip" ]]; then
prompt_with_default "Peer SSH Port" "$default_peer_ssh_port" peer_ssh_port
fi

local ctrl_port prefix config_name config_path
ctrl_port="${ctrl_addr##*:}"
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
config_name="${prefix}${ctrl_port}"
config_path="${RATHOLE_DIR}/${config_name}.toml"

if [[ -f "$config_path" && "$config_name" != "${old_config_name#rathole-}" ]]; then
colorize red "A Rathole tunnel already uses control port ${ctrl_port} on this side. Choose a different port."
press_key
return 1
fi

core_rathole_generate_config "$mode" "$config_path" "$ctrl_addr" "$token" "$ports_csv"
core_rathole_create_service "$prefix" "$ctrl_port" "$config_path" "$mode"

if [[ -n "$old_config_name" && "${old_config_name}" != "rathole-${config_name}" ]]; then
local old_service="rathole-${old_config_name#rathole-}.service"
systemctl disable --now "$old_service" >/dev/null 2>&1
rm -f "${service_dir}/${old_service}"
systemctl daemon-reload
[[ -f "$existing_config" && "$existing_config" != "$config_path" ]] && rm -f "$existing_config"
fi

write_tunnel_meta "rathole-${config_name}" "$peer_ip" "${peer_ssh_port:-22}"
ensure_watchdog_installed
ensure_journal_limits
echo ""
colorize green "✔ Rathole configuration completed successfully!" bold
echo ""
core_rathole_diagnostics "$config_path"
}

core_rathole_configure_tunnel() {
core_rathole_ensure_ready
clear
colorize green "1) Configure IRAN (Server)" bold
colorize magenta "2) Configure KHAREJ (Client)" bold
echo ""
read -r -p "Enter your choice: " choice
case "$choice" in
1) core_rathole_configure "server" ;;
2) core_rathole_configure "client" ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
}

core_rathole_diagnostics() {
local config_path="$1"
if [[ ! -f "$config_path" ]]; then
colorize red "Config not found."; press_key; return 1
fi
local config_name role port peer_ip ssh_port service_name my_label peer_label
config_name=$(core_rathole_config_name "$config_path")
role=$(core_rathole_role "$config_path")
port=$(core_rathole_port_number "$config_path" "$role")
service_name="rathole-$(basename "${config_path%.toml}").service"
peer_ip=$(read_tunnel_meta "$config_name" "peer_ip")
ssh_port=$(read_tunnel_meta "$config_name" "peer_ssh_port")
[[ -z "$ssh_port" ]] && ssh_port="22"
if [[ "$role" == "server" ]]; then my_label="IRAN"; peer_label="KHAREJ"; else my_label="KHAREJ"; peer_label="IRAN"; fi

clear
colorize cyan "Tunnel Diagnostics: $(basename "${config_path%.toml}") (Rathole)" bold
echo ""
colorize blue "── ${my_label} side (this server) ──" bold
local ready=1 reason=""
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
ready=0; reason="service ${service_name} is not active"
fi
if [[ "$ready" == "1" ]]; then
colorize green "✔ ${my_label} side is ready"
else
colorize red "✘ ${my_label} side is not ready — ${reason}"
fi
echo ""

local avg="NA" loss="NA"
if [[ -z "$peer_ip" ]]; then
colorize yellow "Peer IP is not set. Set it from the tunnel's Edit menu to enable full diagnostics."
echo ""
else
colorize blue "── ${peer_label} side (${peer_ip}) ──" bold
read -r avg loss <<< "$(ping_stats "$peer_ip" 5)"
if [[ "$avg" == "NA" ]]; then
colorize red "✘ ${peer_label} side is not reachable (ping failed)"
else
colorize green "✔ Reachability: OK"
echo "  Latency: ${avg} ms"
echo "  Packet loss: ${loss}%"
fi
if tcp_port_open "$peer_ip" "$ssh_port" 3; then
colorize green "✔ SSH port (${ssh_port}) is open"
else
colorize red "✘ SSH port (${ssh_port}) is closed or filtered"
fi
if [[ -n "$port" ]]; then
if tcp_port_open "$peer_ip" "$port" 3; then
colorize green "✔ Control port (${port}) is open on this side"
else
colorize yellow "Control port (${port}) did not respond (normal if the peer only listens the other way)"
fi
fi
echo ""
fi

if [[ "$ready" != "1" ]]; then
colorize red "Result: ${my_label} side is not ready."
press_key
return 1
fi
if [[ -z "$peer_ip" || "$avg" == "NA" ]]; then
colorize red "Result: ${peer_label} side is not ready or not reachable."
press_key
return 1
fi

colorize blue "── Final End-to-End Test ──" bold
local result="fail"
local -a ports
IFS=$'\n' read -r -d '' -a ports < <(core_rathole_list_service_ports "$config_path" "$role" && printf '\0')
if [[ "${#ports[@]}" -gt 0 && -n "${ports[0]}" ]]; then
if tcp_port_open "$peer_ip" "${ports[0]}" 3; then
colorize green "✔ Forwarded port ${ports[0]} is reachable on ${peer_ip}"
result="ok"
else
colorize red "✘ Services are up but forwarded port ${ports[0]} isn't answering on ${peer_ip} yet."
colorize yellow "Check that both sides use the same token and control port."
fi
else
colorize green "✔ Both sides are reachable and services are active."
result="ok"
fi
write_tunnel_last_test "$config_name" "$result"
echo ""
press_key
}

core_rathole_benchmark() {
local config_path="$1" config_name role peer_ip port
config_name=$(core_rathole_config_name "$config_path")
role=$(core_rathole_role "$config_path")
peer_ip=$(read_tunnel_meta "$config_name" "peer_ip")
if [[ -z "$peer_ip" ]]; then
colorize red "Peer IP is not set — set it from the Edit menu first."
press_key
return 1
fi
port=$(core_rathole_port_number "$config_path" "$role")
[[ -z "$port" ]] && port=$(read_tunnel_meta "$config_name" "peer_ssh_port")

clear
colorize cyan "Protocol Benchmark — target: ${peer_ip}" bold
colorize yellow "Note: real throughput needs iperf3 running on the peer (iperf3 -s), otherwise it shows N/A."
echo ""
local -A RESULTS
colorize yellow "Testing TCP (port ${port})..."
RESULTS[tcp]=$(benchmark_tcp_probe "$peer_ip" "$port")
colorize yellow "Testing ICMP..."
RESULTS[icmp]=$(benchmark_icmp_probe "$peer_ip")

echo ""
colorize cyan "Test results:" bold
echo ""
local best_key="" best_score=999999999 i=1 key label lat loss thr status score
for key in tcp icmp; do
IFS=' ' read -r lat loss thr <<< "${RESULTS[$key]}"
[[ "$key" == "tcp" ]] && label="TCP (port ${port})" || label="ICMP"
status=$(status_label "$lat" "$loss")
score=$(score_result "$lat" "$loss")
echo "$i. $label"
if [[ "$lat" == "NA" ]]; then
echo "   Not reachable"
else
echo "   Latency: ${lat}ms"
echo "   Loss: ${loss}%"
if [[ "$thr" != "NA" ]]; then
echo "   Speed: ${thr}Mbps"
else
echo "   Speed: N/A (iperf3 not available on the peer)"
fi
fi
echo "   Status: $status"
echo ""
if (( score < best_score )); then best_score=$score; best_key="$label"; fi
((i++))
done
if [[ -n "$best_key" ]]; then
colorize green "Recommendation: ${best_key} is the best choice."
else
colorize yellow "Recommendation: neither probe was reliably reachable."
fi
write_tunnel_last_test "$config_name" "benchmark:${best_key:-none}"
echo ""
press_key
}

core_rathole_edit() {
local config_path="$1" mode
local role
role=$(core_rathole_role "$config_path")
[[ "$role" == "server" ]] && mode="server" || mode="client"
local config_name service_name service_path
config_name=$(basename "${config_path%.toml}")
service_name="rathole-${config_name}.service"
service_path="${service_dir}/${service_name}"
local backup_dir
backup_dir=$(backup_tunnel "$config_path" "$service_path" "rathole-${config_name}")
colorize green "Current config backed up: $backup_dir"
core_rathole_configure "$mode" "$config_path"
local new_service_name
new_service_name="rathole-$(basename "${config_path%.toml}").service"
if [[ ! -f "$config_path" ]]; then
new_service_name="$service_name"
fi
sleep 2
if systemctl is-active --quiet "$new_service_name" 2>/dev/null; then
colorize green "✔ Rathole tunnel is healthy after edit."
rm -rf "$backup_dir"
else
colorize red "✘ Service failed to come back up! Rolling back..."
systemctl disable --now "$new_service_name" >/dev/null 2>&1
rm -f "${service_dir}/${new_service_name}" "$config_path"
systemctl daemon-reload
restore_tunnel_backup "$backup_dir" "$config_path" "$service_path" "$service_name"
if systemctl is-active --quiet "$service_name"; then
colorize green "✔ Rollback succeeded, tunnel restored to its previous state."
else
colorize red "✘ Rollback also failed! Check logs manually: journalctl -eu ${service_name}"
fi
press_key
fi
}

core_rathole_toggle_enabled() {
toggle_tunnel_enabled "$1"
}

core_rathole_destroy() {
local config_path="$1"
local silent="${2:-}"
local config_name service_name service_path
config_name=$(basename "${config_path%.toml}")
service_name="rathole-${config_name}.service"
service_path="${service_dir}/${service_name}"
[[ -f "$config_path" ]] && rm -f "$config_path"
if [[ -f "$service_path" ]]; then
systemctl is-active --quiet "$service_name" && systemctl disable --now "$service_name" >/dev/null 2>&1
rm -f "$service_path"
fi
systemctl daemon-reload
if [[ "$silent" != "--silent" ]]; then
echo
colorize green "Tunnel destroyed successfully!" bold
echo
press_key
else
colorize green "✔ Removed rathole-${config_name}"
fi
}

core_rathole_destroy_all() {
local config_path
for config_path in "${RATHOLE_DIR}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
core_rathole_destroy "$config_path" --silent
done
}

core_rathole_watchdog_check_all() {
local config_path config_name service_name
for config_path in "${RATHOLE_DIR}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
config_name=$(basename "${config_path%.toml}")
service_name="rathole-${config_name}.service"
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
logger -t rathole-watchdog "${service_name} is inactive, restarting" 2>/dev/null
systemctl restart "$service_name" 2>/dev/null
fi
done
}

core_rathole_detail_page() {
local config_path="$1"
local config_name service_name role port peer_ip last_test last_time
config_name=$(basename "${config_path%.toml}")
service_name="rathole-${config_name}.service"
while true; do
[[ -f "$config_path" ]] || return
role=$(core_rathole_role "$config_path")
port=$(core_rathole_port_number "$config_path" "$role")
peer_ip=$(read_tunnel_meta "rathole-${config_name}" "peer_ip")
clear
colorize cyan "Tunnel: ${config_name} (Rathole)" bold
echo ""
if systemctl is-active --quiet "$service_name"; then
colorize green "Status: Active"
else
colorize red "Status: Inactive"
fi
IFS='|' read -r last_test last_time <<< "$(read_tunnel_last_test "rathole-${config_name}")"
echo "Last test: ${last_test} (${last_time})"
echo "Tunnel type: rathole / tcp"
echo "Role: $([[ "$role" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")"
echo "Control port: ${port}"
if [[ -n "$peer_ip" ]]; then echo "Peer IP: ${peer_ip}"; else echo "Peer IP: not set"; fi
local ports_count
ports_count=$(core_rathole_list_service_ports "$config_path" "$role" | grep -c .)
echo "Forwarded ports: ${ports_count:-0}"
local traffic
traffic=$(tunnel_traffic_stats "$service_name")
if [[ -n "$traffic" ]]; then
echo "Traffic: ${traffic}"
else
echo "Traffic: N/A (re-save via Edit to enable tracking on this tunnel)"
fi
echo ""
colorize green "1) Edit tunnel"
colorize cyan "2) Retest (Diagnostics)"
colorize magenta "3) Benchmark"
echo "4) View service logs"
echo "5) View service status"
colorize yellow "6) Restart service"
colorize red "7) Remove this tunnel"
echo "0) Back"
echo ""
read -r -p "Choice: " choice
case "$choice" in
1) core_rathole_edit "$config_path" ;;
2) core_rathole_diagnostics "$config_path" ;;
3) core_rathole_benchmark "$config_path" ;;
4) view_service_logs "$service_name" ;;
5) view_service_status "$service_name" ;;
6) restart_service "$service_name" ;;
7) core_rathole_destroy "$config_path"; return ;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}

core_rathole_tunnel_management() {
if ! ls "${RATHOLE_DIR}"/*.toml 1> /dev/null 2>&1; then
colorize red "No Rathole config files found." bold
press_key
return 1
fi
clear
colorize cyan "Existing Rathole services:" bold
echo
local index=1 config_path config_name port
local -a configs=()
for config_path in "${RATHOLE_DIR}"/{iran,kharej}*.toml; do
[ -f "$config_path" ] || continue
config_name=$(basename "$config_path")
if [[ "$config_name" =~ ^iran([0-9]+)\.toml$ ]]; then
port="${BASH_REMATCH[1]}"
configs+=("$config_path")
echo -e "\033[35m${index}\033[0m) \033[32mIran\033[0m (port: \033[33m$port\033[0m)"
((index++))
elif [[ "$config_name" =~ ^kharej([0-9]+)\.toml$ ]]; then
port="${BASH_REMATCH[1]}"
configs+=("$config_path")
echo -e "\033[35m${index}\033[0m) \033[32mKharej\033[0m (port: \033[33m$port\033[0m)"
((index++))
fi
done
echo
echo -ne "Enter your choice (0 to return): "
read -r choice
[[ "$choice" == "0" ]] && return
while ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#configs[@]} )); do
colorize red "Invalid choice."
echo -ne "Enter your choice (0 to return): "
read -r choice
[[ "$choice" == "0" ]] && return
done
core_rathole_detail_page "${configs[$((choice - 1))]}"
}

core_rathole_check_status() {
if ! ls "${RATHOLE_DIR}"/*.toml 1> /dev/null 2>&1; then
colorize red "No Rathole config files found." bold
press_key
return 1
fi
clear
colorize yellow "Checking all Rathole services status..." bold
sleep 1
echo
local config_path config_name service_name port
for config_path in "${RATHOLE_DIR}"/{iran,kharej}*.toml; do
[ -f "$config_path" ] || continue
config_name=$(basename "$config_path")
config_name="${config_name%.toml}"
service_name="rathole-${config_name}.service"
if [[ "$config_name" =~ ^iran([0-9]+)$ ]]; then
port="${BASH_REMATCH[1]}"
if systemctl is-active --quiet "$service_name"; then
colorize green "Iran service (port $port) is running"
else
colorize red "Iran service (port $port) is not running"
fi
elif [[ "$config_name" =~ ^kharej([0-9]+)$ ]]; then
port="${BASH_REMATCH[1]}"
if systemctl is-active --quiet "$service_name"; then
colorize green "Kharej service (port $port) is running"
else
colorize red "Kharej service (port $port) is not running"
fi
fi
done
echo
press_key
}

core_rathole_menu() {
core_rathole_ensure_ready
while true; do
clear
colorize cyan "Rathole" bold
echo ""
colorize green " 1. Configure a new tunnel" bold
colorize red " 2. Tunnel management" bold
colorize cyan " 3. Check tunnel status" bold
echo " 0. Back"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Enter your choice [0-3]: " choice
case "$choice" in
1) core_rathole_configure_tunnel ;;
2) core_rathole_tunnel_management ;;
3) core_rathole_check_status ;;
0) return ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
done
}

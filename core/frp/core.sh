#!/usr/bin/env bash
# FRP tunnel core. Mirrors Rathole/Hysteria2's workflow (configure/edit/
# diagnostics/benchmark/backup/watchdog/uninstall) but drives FRP's own two
# separate binaries (frps for server, frpc for client) and TOML dialect.
# Requires lib/common.sh and core/backhaul/core.sh to already be sourced (for
# the shared write_tunnel_meta/read_tunnel_meta/write_tunnel_last_test/
# read_tunnel_last_test/ensure_watchdog_installed helpers, same layering
# Rathole and Hysteria2 already rely on).
#
# Layout: ${config_dir}/frp/{frps_bin,frpc_bin}, .../iranN.toml (server,
# frps), .../kharejN.toml (client, frpc). Services: frp-iranN.service /
# frp-kharejN.service. Config identity for the shared meta/status/backup
# helpers is prefixed "frp-" so it never collides with a same-numbered
# tunnel from another core.
#
# Generated frps.toml/frpc.toml use bracketed [section] tables (not dotted
# `auth.token = ...` keys) specifically so the existing generic toml_get()
# helper (lib/common.sh) can read them back — both forms are equivalent TOML,
# this just keeps the file parseable by the same tool every other core uses.
# The [[proxies]] array-of-tables (frpc's port-forwarding list) is NOT
# something toml_get can walk, so it gets its own small awk-based getter
# below (frp_list_proxies), same approach as Hysteria2's YAML getters.
#
# Port-forwarding direction: frpc's remotePort is the port opened on frps
# (IRAN) that end users hit; localPort/localIP is where the real service is
# reachable from the frpc (KHAREJ) machine. That's the same "forwarded port
# lives on IRAN, real backend reachable from KHAREJ" shape Backhaul and
# Rathole already use, so the "Ports to forward" prompt (remote=local) lives
# on the client (KHAREJ) side, matching where FRP's own config puts it.

FRP_REPO="fatedier/frp"
FRP_DIR="${config_dir}/frp"
FRP_SERVER_BIN="${FRP_DIR}/frps_bin"
FRP_CLIENT_BIN="${FRP_DIR}/frpc_bin"

core_frp_ensure_ready() {
mkdir -p "$FRP_DIR"
core_frp_install
}

core_frp_install() {
[[ -f "$FRP_SERVER_BIN" && -f "$FRP_CLIENT_BIN" ]] && return 0
core_frp_download_binaries
}

core_frp_download_binaries() {
mkdir -p "$FRP_DIR"
colorize yellow "Installing FRP..."
local arch asset
arch=$(uname -m)
case "$arch" in
x86_64) asset="amd64" ;;
aarch64|arm64) asset="arm64" ;;
*)
colorize red "Unsupported architecture for FRP: ${arch}."
press_key
return 1
;;
esac
local latest_url tag version
latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${FRP_REPO}/releases/latest" 2>/dev/null)
tag="${latest_url##*/}"
if [[ -z "$tag" ]]; then
colorize red "Could not determine the latest FRP release."
press_key
return 1
fi
version="${tag#v}"
local pkg="frp_${version}_linux_${asset}"
local dl_url="https://github.com/${FRP_REPO}/releases/download/${tag}/${pkg}.tar.gz"
local checksums_url="https://github.com/${FRP_REPO}/releases/download/${tag}/frp_sha256_checksums.txt"
local tmp_dir
tmp_dir=$(mktemp -d)
if ! curl -fsSL "$dl_url" -o "${tmp_dir}/frp.tar.gz"; then
colorize red "Download failed: ${dl_url}"
rm -rf "$tmp_dir"
press_key
return 1
fi
local expected_hash actual_hash
expected_hash=$(curl -fsSL "$checksums_url" 2>/dev/null | grep "${pkg}\\.tar\\.gz\$" | awk '{print $1}')
if [[ -n "$expected_hash" ]]; then
actual_hash=$(sha256sum "${tmp_dir}/frp.tar.gz" 2>/dev/null | awk '{print $1}')
if [[ "$actual_hash" != "$expected_hash" ]]; then
colorize red "Checksum verification failed for the FRP archive! Refusing to install."
rm -rf "$tmp_dir"
press_key
return 1
fi
else
colorize yellow "Warning: could not fetch the release checksum; installing unverified."
fi
tar -xzf "${tmp_dir}/frp.tar.gz" -C "$tmp_dir"
if [[ ! -f "${tmp_dir}/${pkg}/frps" || ! -f "${tmp_dir}/${pkg}/frpc" ]]; then
colorize red "Downloaded archive did not contain the expected frps/frpc binaries."
rm -rf "$tmp_dir"
press_key
return 1
fi
chmod +x "${tmp_dir}/${pkg}/frps" "${tmp_dir}/${pkg}/frpc"
if ! "${tmp_dir}/${pkg}/frps" --version &> /dev/null || ! "${tmp_dir}/${pkg}/frpc" --version &> /dev/null; then
colorize red "Downloaded FRP binaries failed a basic sanity check (--version)."
rm -rf "$tmp_dir"
press_key
return 1
fi
local tmp_s tmp_c
tmp_s=$(mktemp "${FRP_DIR}/.frps_bin.XXXXXX")
tmp_c=$(mktemp "${FRP_DIR}/.frpc_bin.XXXXXX")
cp "${tmp_dir}/${pkg}/frps" "$tmp_s"
cp "${tmp_dir}/${pkg}/frpc" "$tmp_c"
chmod +x "$tmp_s" "$tmp_c"
mv -f "$tmp_s" "$FRP_SERVER_BIN"
mv -f "$tmp_c" "$FRP_CLIENT_BIN"
rm -rf "$tmp_dir"
colorize green "✔ FRP ${tag} installed."
}

core_frp_update() {
colorize yellow "Checking for a newer FRP core..."
local backup_s="" backup_c=""
if [[ -f "$FRP_SERVER_BIN" ]]; then
backup_s=$(mktemp "${FRP_DIR}/.frps_bin_backup.XXXXXX")
cp "$FRP_SERVER_BIN" "$backup_s"
fi
if [[ -f "$FRP_CLIENT_BIN" ]]; then
backup_c=$(mktemp "${FRP_DIR}/.frpc_bin_backup.XXXXXX")
cp "$FRP_CLIENT_BIN" "$backup_c"
fi
if ! core_frp_download_binaries; then
[[ -n "$backup_s" ]] && mv -f "$backup_s" "$FRP_SERVER_BIN"
[[ -n "$backup_c" ]] && mv -f "$backup_c" "$FRP_CLIENT_BIN"
[[ -n "$backup_s$backup_c" ]] && colorize yellow "Restored the previous core."
return 1
fi
if ! "$FRP_SERVER_BIN" --version &> /dev/null || ! "$FRP_CLIENT_BIN" --version &> /dev/null; then
colorize red "New core failed a basic sanity check."
[[ -n "$backup_s" ]] && mv -f "$backup_s" "$FRP_SERVER_BIN"
[[ -n "$backup_c" ]] && mv -f "$backup_c" "$FRP_CLIENT_BIN"
colorize yellow "Restored the previous core."
press_key
return 1
fi
[[ -n "$backup_s" ]] && rm -f "$backup_s"
[[ -n "$backup_c" ]] && rm -f "$backup_c"
press_key
}

# ── TOML getters (bindPort/serverAddr/serverPort have no [section]
# wrapper — small dedicated getters, same style as toml_tun_name(). Everything
# under a real [section] uses the shared toml_get(). ──

frp_get_bind_port() {
grep '^bindPort' "$1" 2>/dev/null | head -1 | grep -oE '[0-9]+'
}
frp_get_server_addr() {
grep '^serverAddr' "$1" 2>/dev/null | head -1 | sed -E 's/^serverAddr[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/'
}
frp_get_server_port() {
grep '^serverPort' "$1" 2>/dev/null | head -1 | grep -oE '[0-9]+'
}
frp_list_proxies() {
awk '
/^\[\[proxies\]\]/ { if (name!="") print name, type, lport, rport; name=""; type=""; lport=""; rport="" }
/^name = / { match($0, /"[^"]*"/); name=substr($0, RSTART+1, RLENGTH-2) }
/^type = / { match($0, /"[^"]*"/); type=substr($0, RSTART+1, RLENGTH-2) }
/^localPort = / { match($0, /[0-9]+/); lport=substr($0, RSTART, RLENGTH) }
/^remotePort = / { match($0, /[0-9]+/); rport=substr($0, RSTART, RLENGTH) }
END { if (name!="") print name, type, lport, rport }
' "$1" 2>/dev/null
}
frp_proxies_csv() {
local file="$1" name type lport rport
local -a out=()
while read -r name type lport rport; do
[[ -z "$rport" ]] && continue
if [[ "$rport" == "$lport" ]]; then out+=("$rport"); else out+=("${rport}=${lport}"); fi
done < <(frp_list_proxies "$file")
local IFS=,
echo "${out[*]}"
}

core_frp_role() {
local file="$1"
grep -q '^bindPort' "$file" 2>/dev/null && { echo "server"; return; }
grep -q '^serverAddr' "$file" 2>/dev/null && echo "client"
}
core_frp_config_name() {
echo "frp-$(basename "${1%.toml}")"
}
core_frp_port_number() {
local file="$1" role="$2"
if [[ "$role" == "server" ]]; then
frp_get_bind_port "$file"
else
frp_get_server_port "$file"
fi
}
core_frp_suggest_free_port() {
local mode="$1" prefix port=7000
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
while [[ -f "${FRP_DIR}/${prefix}${port}.toml" ]] || is_port_listening_system_wide "$port"; do
((port++))
done
echo "$port"
}

core_frp_generate_server_config() {
local output_file="$1" port="$2" token="$3"
{
echo "bindPort = ${port}"
echo ""
echo "[auth]"
echo "method = \"token\""
echo "token = \"${token}\""
} > "$output_file"
}

core_frp_generate_client_config() {
local output_file="$1" server_ip="$2" server_port="$3" token="$4" ports_csv="$5"
{
echo "serverAddr = \"${server_ip}\""
echo "serverPort = ${server_port}"
echo ""
echo "[auth]"
echo "method = \"token\""
echo "token = \"${token}\""
local -a entries=()
IFS=',' read -r -a entries <<< "$ports_csv"
local entry remote local_port i=0
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r remote local_port <<< "$(parse_port_entry "$entry")"
echo ""
echo "[[proxies]]"
echo "name = \"p${i}\""
echo "type = \"tcp\""
echo "localIP = \"127.0.0.1\""
echo "localPort = ${local_port}"
echo "remotePort = ${remote}"
((i++))
done
} > "$output_file"
}

core_frp_create_service() {
local type="$1" port="$2" config_file="$3" mode="$4"
local bin sub_desc
if [[ "$mode" == "server" ]]; then bin="$FRP_SERVER_BIN"; sub_desc="frps"; else bin="$FRP_CLIENT_BIN"; sub_desc="frpc"; fi
local service_file="${service_dir}/frp-${type}${port}.service"
local desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"
cat > "$service_file" <<EOF
[Unit]
Description=FRP (${sub_desc}) $desc_type Port $port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${bin} -c ${config_file}
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
systemctl enable --now "frp-${type}${port}.service" >/dev/null 2>&1
}

core_frp_configure() {
local mode="$1"
local existing_config="$2"
local default_ctrl_addr="" default_token="" default_ports="" default_peer_ip="" default_peer_ssh_port="22"
local old_config_name=""
if [[ -n "$existing_config" && -f "$existing_config" ]]; then
if [[ "$mode" == "server" ]]; then
default_ctrl_addr=":$(frp_get_bind_port "$existing_config")"
default_token=$(toml_get "$existing_config" "auth" "token")
else
default_ctrl_addr="$(frp_get_server_addr "$existing_config"):$(frp_get_server_port "$existing_config")"
default_token=$(toml_get "$existing_config" "auth" "token")
default_ports=$(frp_proxies_csv "$existing_config")
fi
old_config_name=$(core_frp_config_name "$existing_config")
default_peer_ip=$(read_tunnel_meta "$old_config_name" "peer_ip")
default_peer_ssh_port=$(read_tunnel_meta "$old_config_name" "peer_ssh_port")
[[ -z "$default_peer_ssh_port" ]] && default_peer_ssh_port="22"
fi

clear
colorize cyan "Configuring FRP $([[ "$mode" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")" bold
echo ""

local ctrl_addr token ports_csv peer_ip peer_ssh_port

if [[ "$mode" == "server" ]]; then
local suggested_port="${default_ctrl_addr#:}"
[[ -z "$suggested_port" ]] && suggested_port=$(core_frp_suggest_free_port "server")
prompt_with_default "Bind Port" "$suggested_port" ctrl_addr
[[ -n "$ctrl_addr" && "$ctrl_addr" != *:* ]] && ctrl_addr=":${ctrl_addr}"
else
while true; do
prompt_with_default "IRAN Server Address [IP:Port]" "${default_ctrl_addr:-$(get_last_used "client_remote_addr" "")}" ctrl_addr
[[ -n "$ctrl_addr" && "$ctrl_addr" == *:* ]] && break
colorize red "Invalid format. Use IP:Port."
done
fi

local generated_token
generated_token=$(head -c16 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c20)
prompt_with_default "Auth Token (must match on both sides)" "${default_token:-$generated_token}" token

if [[ "$mode" == "client" ]]; then
echo ""
colorize green "Supported formats:"
echo "  1. 443           - open port 443 on IRAN, forward to the same local port"
echo "  2. 443=5000      - open port 443 on IRAN, forward to local port 5000"
echo "  3. 443,8080=9090 - multiple, comma-separated"
echo ""
prompt_with_default "Ports to forward (comma-separated)" "$default_ports" ports_csv
if [[ -z "$ports_csv" ]]; then
colorize red "At least one port is required."
press_key
return 1
fi
fi

echo ""
local peer_ip_default="$default_peer_ip"
if [[ "$mode" == "client" && -z "$peer_ip_default" ]]; then
peer_ip_default="${ctrl_addr%%:*}"
[[ "$peer_ip_default" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || peer_ip_default=""
fi
[[ -z "$peer_ip_default" ]] && peer_ip_default=$(get_last_used "peer_ip" "")
prompt_with_default "Peer Server IP (other side, optional, enables diagnostics)" "$peer_ip_default" peer_ip
if [[ -n "$peer_ip" ]]; then
prompt_with_default "Peer SSH Port" "${default_peer_ssh_port:-22}" peer_ssh_port
fi

local ctrl_port prefix config_name config_path
ctrl_port="${ctrl_addr##*:}"
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
config_name="${prefix}${ctrl_port}"
config_path="${FRP_DIR}/${config_name}.toml"

if [[ -f "$config_path" && "$config_name" != "${old_config_name#frp-}" ]]; then
colorize red "An FRP tunnel already uses port ${ctrl_port} on this side. Choose a different port."
press_key
return 1
fi

if [[ "$mode" == "server" ]]; then
core_frp_generate_server_config "$config_path" "$ctrl_port" "$token"
else
core_frp_generate_client_config "$config_path" "${ctrl_addr%%:*}" "${ctrl_addr##*:}" "$token" "$ports_csv"
fi
core_frp_create_service "$prefix" "$ctrl_port" "$config_path" "$mode"

if [[ -n "$old_config_name" && "${old_config_name}" != "frp-${config_name}" ]]; then
local old_service="frp-${old_config_name#frp-}.service"
systemctl disable --now "$old_service" >/dev/null 2>&1
rm -f "${service_dir}/${old_service}"
systemctl daemon-reload
[[ -f "$existing_config" && "$existing_config" != "$config_path" ]] && rm -f "$existing_config"
fi

save_last_used "transport_type" "frp"
[[ "$mode" == "client" ]] && save_last_used "client_remote_addr" "$ctrl_addr"
save_last_used "peer_ip" "$peer_ip"
write_tunnel_meta "frp-${config_name}" "$peer_ip" "${peer_ssh_port:-22}"
ensure_watchdog_installed
ensure_journal_limits
echo ""
colorize green "✔ FRP configuration completed successfully!" bold
echo ""
core_frp_diagnostics "$config_path"
}

core_frp_configure_tunnel() {
core_frp_ensure_ready
clear
colorize green "1) Configure IRAN (Server)" bold
colorize magenta "2) Configure KHAREJ (Client)" bold
echo ""
read -r -p "Enter your choice: " choice
case "$choice" in
1) core_frp_configure "server" ;;
2) core_frp_configure "client" ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
}

core_frp_diagnostics() {
local config_path="$1"
if [[ ! -f "$config_path" ]]; then
colorize red "Config not found."; press_key; return 1
fi
local config_name role port peer_ip ssh_port service_name my_label peer_label
config_name=$(core_frp_config_name "$config_path")
role=$(core_frp_role "$config_path")
port=$(core_frp_port_number "$config_path" "$role")
service_name="frp-$(basename "${config_path%.toml}").service"
peer_ip=$(read_tunnel_meta "$config_name" "peer_ip")
ssh_port=$(read_tunnel_meta "$config_name" "peer_ssh_port")
[[ -z "$ssh_port" ]] && ssh_port="22"
if [[ "$role" == "server" ]]; then my_label="IRAN"; peer_label="KHAREJ"; else my_label="KHAREJ"; peer_label="IRAN"; fi

clear
colorize cyan "Tunnel Diagnostics: $(basename "${config_path%.toml}") (FRP)" bold
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
IFS=$'\n' read -r -d '' -a ports < <(frp_list_proxies "$config_path" | awk '{print $4}' && printf '\0')
if [[ "${#ports[@]}" -gt 0 && -n "${ports[0]}" ]]; then
if tcp_port_open "$peer_ip" "${ports[0]}" 3; then
colorize green "✔ Forwarded port ${ports[0]} is reachable on ${peer_ip}"
result="ok"
else
colorize red "✘ Services are up but forwarded port ${ports[0]} isn't answering on ${peer_ip} yet."
colorize yellow "Check that both sides use the same auth token."
fi
else
colorize green "✔ Both sides are reachable and services are active."
result="ok"
fi
write_tunnel_last_test "$config_name" "$result"
echo ""
press_key
}

core_frp_benchmark() {
local config_path="$1" config_name role peer_ip port
config_name=$(core_frp_config_name "$config_path")
role=$(core_frp_role "$config_path")
peer_ip=$(read_tunnel_meta "$config_name" "peer_ip")
if [[ -z "$peer_ip" ]]; then
colorize red "Peer IP is not set — set it from the Edit menu first."
press_key
return 1
fi
port=$(core_frp_port_number "$config_path" "$role")
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

core_frp_edit() {
local config_path="$1" mode
local role
role=$(core_frp_role "$config_path")
[[ "$role" == "server" ]] && mode="server" || mode="client"
local config_name service_name service_path
config_name=$(basename "${config_path%.toml}")
service_name="frp-${config_name}.service"
service_path="${service_dir}/${service_name}"
local backup_dir
backup_dir=$(backup_tunnel "$config_path" "$service_path" "frp-${config_name}")
colorize green "Current config backed up: $backup_dir"
core_frp_configure "$mode" "$config_path"
local new_service_name
new_service_name="frp-$(basename "${config_path%.toml}").service"
if [[ ! -f "$config_path" ]]; then
new_service_name="$service_name"
fi
sleep 2
if systemctl is-active --quiet "$new_service_name" 2>/dev/null; then
colorize green "✔ FRP tunnel is healthy after edit."
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

core_frp_toggle_enabled() {
toggle_tunnel_enabled "$1"
}

core_frp_destroy() {
local config_path="$1"
local silent="${2:-}"
local config_name service_name service_path
config_name=$(basename "${config_path%.toml}")
service_name="frp-${config_name}.service"
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
colorize green "✔ Removed frp-${config_name}"
fi
}

core_frp_destroy_all() {
local config_path
for config_path in "${FRP_DIR}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
core_frp_destroy "$config_path" --silent
done
}

core_frp_watchdog_check_all() {
local config_path config_name service_name
for config_path in "${FRP_DIR}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
config_name=$(basename "${config_path%.toml}")
service_name="frp-${config_name}.service"
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
logger -t frp-watchdog "${service_name} is inactive, restarting" 2>/dev/null
systemctl restart "$service_name" 2>/dev/null
fi
done
}

core_frp_detail_page() {
local config_path="$1"
local config_name service_name role port peer_ip last_test last_time
config_name=$(basename "${config_path%.toml}")
service_name="frp-${config_name}.service"
while true; do
[[ -f "$config_path" ]] || return
role=$(core_frp_role "$config_path")
port=$(core_frp_port_number "$config_path" "$role")
peer_ip=$(read_tunnel_meta "frp-${config_name}" "peer_ip")
clear
colorize cyan "Tunnel: ${config_name} (FRP)" bold
echo ""
if systemctl is-active --quiet "$service_name"; then
colorize green "Status: Active"
else
colorize red "Status: Inactive"
fi
IFS='|' read -r last_test last_time <<< "$(read_tunnel_last_test "frp-${config_name}")"
echo "Last test: ${last_test} (${last_time})"
echo "Tunnel type: frp / tcp"
echo "Role: $([[ "$role" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")"
echo "Port: ${port}"
if [[ -n "$peer_ip" ]]; then echo "Peer IP: ${peer_ip}"; else echo "Peer IP: not set"; fi
if [[ "$role" == "client" ]]; then
local ports_count
ports_count=$(frp_list_proxies "$config_path" | grep -c .)
echo "Forwarded ports: ${ports_count:-0}"
fi
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
1) core_frp_edit "$config_path" ;;
2) core_frp_diagnostics "$config_path" ;;
3) core_frp_benchmark "$config_path" ;;
4) view_service_logs "$service_name" ;;
5) view_service_status "$service_name" ;;
6) restart_service "$service_name" ;;
7) core_frp_destroy "$config_path"; return ;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}

core_frp_tunnel_management() {
if ! ls "${FRP_DIR}"/*.toml 1> /dev/null 2>&1; then
colorize red "No FRP config files found." bold
press_key
return 1
fi
clear
colorize cyan "Existing FRP services:" bold
echo
local index=1 config_path config_name port
local -a configs=()
for config_path in "${FRP_DIR}"/{iran,kharej}*.toml; do
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
core_frp_detail_page "${configs[$((choice - 1))]}"
}

core_frp_check_status() {
if ! ls "${FRP_DIR}"/*.toml 1> /dev/null 2>&1; then
colorize red "No FRP config files found." bold
press_key
return 1
fi
clear
colorize yellow "Checking all FRP services status..." bold
sleep 1
echo
local config_path config_name service_name port
for config_path in "${FRP_DIR}"/{iran,kharej}*.toml; do
[ -f "$config_path" ] || continue
config_name=$(basename "$config_path")
config_name="${config_name%.toml}"
service_name="frp-${config_name}.service"
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

core_frp_menu() {
core_frp_ensure_ready
while true; do
clear
colorize cyan "FRP" bold
echo ""
colorize green " 1. Configure a new tunnel" bold
colorize red " 2. Tunnel management" bold
colorize cyan " 3. Check tunnel status" bold
echo " 4. Update FRP core"
echo " 0. Back"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Enter your choice [0-4]: " choice
case "$choice" in
1) core_frp_configure_tunnel ;;
2) core_frp_tunnel_management ;;
3) core_frp_check_status ;;
4) core_frp_update ;;
0) return ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
done
}

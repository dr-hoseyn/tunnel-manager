#!/usr/bin/env bash
# Hysteria2 tunnel core. Mirrors Rathole's workflow (configure/edit/
# diagnostics/benchmark/backup/watchdog/uninstall) but speaks Hysteria2's own
# YAML config and runs over QUIC/UDP instead of plain TCP — the point of this
# core is DPI/throttling resistance (obfuscated QUIC), not raw throughput.
# Requires lib/common.sh and core/backhaul/core.sh to already be sourced (for
# the shared write_tunnel_meta/read_tunnel_meta/write_tunnel_last_test/
# read_tunnel_last_test/ensure_watchdog_installed helpers — same layering
# Rathole already relies on).
#
# Layout: ${config_dir}/hysteria2/hysteria2_bin, .../iranN.yaml (server),
# .../kharejN.yaml (client). Services: hysteria2-iranN.service /
# hysteria2-kharejN.service. Config identity for the shared meta/status/
# backup helpers is prefixed "hysteria2-" so it never collides with a
# Backhaul or Rathole tunnel using the same port number.
#
# Generated YAML uses a fixed, hand-controlled shape (flat, 2-space-per-level
# indent, one field per line) specifically so the hysteria2_yaml_* getters
# below can extract values with plain grep/awk instead of a real YAML parser.
# If you add a new field, keep that discipline or the getters silently break.
#
# The client always sets `tls: insecure: true`. Cert-pinning would need the
# server's cert fingerprint copied over to the client's machine out of band —
# Iran and Kharej are separate servers with separate panel installs, so
# there's no in-panel channel to move that value automatically. The real
# trust boundary here is the auth password (and obfs password, if enabled),
# not certificate identity — same trust model Backhaul's own transports use.

HYSTERIA2_REPO="apernet/hysteria"
HYSTERIA2_DIR="${config_dir}/hysteria2"
HYSTERIA2_BIN="${HYSTERIA2_DIR}/hysteria2_bin"

core_hysteria2_ensure_ready() {
mkdir -p "$HYSTERIA2_DIR"
core_hysteria2_install
}

core_hysteria2_install() {
[[ -f "$HYSTERIA2_BIN" ]] && return 0
core_hysteria2_download_binary
}

core_hysteria2_download_binary() {
mkdir -p "$HYSTERIA2_DIR"
colorize yellow "Installing Hysteria2..."
local arch asset
arch=$(uname -m)
case "$arch" in
x86_64) asset="hysteria-linux-amd64" ;;
aarch64|arm64) asset="hysteria-linux-arm64" ;;
*)
colorize red "Unsupported architecture for Hysteria2: ${arch}."
press_key
return 1
;;
esac
local latest_url tag
latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${HYSTERIA2_REPO}/releases/latest" 2>/dev/null)
tag="${latest_url#*/tag/}"
if [[ -z "$tag" || "$tag" == "$latest_url" ]]; then
colorize red "Could not determine the latest Hysteria2 release."
press_key
return 1
fi
local dl_url="https://github.com/${HYSTERIA2_REPO}/releases/download/${tag}/${asset}"
local hashes_url="https://github.com/${HYSTERIA2_REPO}/releases/download/${tag}/hashes.txt"
local tmp_dir
tmp_dir=$(mktemp -d)
if ! curl -fsSL "$dl_url" -o "${tmp_dir}/hysteria"; then
colorize red "Download failed: ${dl_url}"
rm -rf "$tmp_dir"
press_key
return 1
fi
local expected_hash actual_hash
expected_hash=$(curl -fsSL "$hashes_url" 2>/dev/null | grep "build/${asset}\$" | awk '{print $1}')
if [[ -n "$expected_hash" ]]; then
actual_hash=$(sha256sum "${tmp_dir}/hysteria" 2>/dev/null | awk '{print $1}')
if [[ "$actual_hash" != "$expected_hash" ]]; then
colorize red "Checksum verification failed for the Hysteria2 binary! Refusing to install."
rm -rf "$tmp_dir"
press_key
return 1
fi
else
colorize yellow "Warning: could not fetch the release checksum; installing unverified."
fi
chmod +x "${tmp_dir}/hysteria"
if ! "${tmp_dir}/hysteria" --help &> /dev/null; then
colorize red "Downloaded Hysteria2 binary failed a basic sanity check (--help)."
rm -rf "$tmp_dir"
press_key
return 1
fi
local tmp_bin
tmp_bin=$(mktemp "${HYSTERIA2_DIR}/.hysteria2_bin.XXXXXX")
cp "${tmp_dir}/hysteria" "$tmp_bin"
chmod +x "$tmp_bin"
mv -f "$tmp_bin" "$HYSTERIA2_BIN"
rm -rf "$tmp_dir"
colorize green "✔ Hysteria2 ${tag} installed."
}

core_hysteria2_update() {
colorize yellow "Checking for a newer Hysteria2 core..."
local backup_bin=""
if [[ -f "$HYSTERIA2_BIN" ]]; then
backup_bin=$(mktemp "${HYSTERIA2_DIR}/.hysteria2_bin_backup.XXXXXX")
cp "$HYSTERIA2_BIN" "$backup_bin"
fi
if ! core_hysteria2_download_binary; then
[[ -n "$backup_bin" ]] && { mv -f "$backup_bin" "$HYSTERIA2_BIN"; colorize yellow "Restored the previous core."; }
return 1
fi
if ! "$HYSTERIA2_BIN" --help &> /dev/null; then
colorize red "New core failed a basic sanity check."
if [[ -n "$backup_bin" ]]; then
mv -f "$backup_bin" "$HYSTERIA2_BIN"
colorize yellow "Restored the previous core."
fi
press_key
return 1
fi
[[ -n "$backup_bin" ]] && rm -f "$backup_bin"
press_key
}

core_hysteria2_ensure_cert() {
ensure_cert_fresh "$CERT_FILE" "$KEY_FILE"
}

# ── YAML getters (see the file-header note: fixed generated shape only) ──

hysteria2_get_listen_port() {
grep '^listen:' "$1" 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^://'
}
hysteria2_get_server_addr() {
grep '^server:' "$1" 2>/dev/null | head -1 | cut -d' ' -f2-
}
hysteria2_get_auth_password() {
local file="$1"
if grep -q '^auth: ' "$file" 2>/dev/null; then
grep '^auth: ' "$file" | head -1 | cut -d' ' -f2-
else
grep '^  password: ' "$file" 2>/dev/null | head -1 | sed 's/^  password: //'
fi
}
hysteria2_obfs_enabled() {
grep -q '^obfs:' "$1" 2>/dev/null && echo "true" || echo "false"
}
hysteria2_get_obfs_password() {
grep '^    password: ' "$1" 2>/dev/null | head -1 | sed 's/^    password: //'
}
hysteria2_get_tls_sni() {
grep '^  sni: ' "$1" 2>/dev/null | head -1 | sed 's/^  sni: //'
}
hysteria2_list_forwards() {
awk '
/^tcpForwarding:/ { in_fwd=1; next }
/^[A-Za-z]/ { in_fwd=0 }
in_fwd && /- listen:/ { match($0, /:[0-9]+$/); l=substr($0, RSTART+1, RLENGTH-1) }
in_fwd && /remote:/ { match($0, /:[0-9]+$/); r=substr($0, RSTART+1, RLENGTH-1); print l, r }
' "$1" 2>/dev/null
}
hysteria2_forwards_csv() {
local file="$1" listen remote
local -a out=()
while read -r listen remote; do
[[ -z "$listen" ]] && continue
if [[ "$listen" == "$remote" ]]; then out+=("$listen"); else out+=("${listen}=${remote}"); fi
done < <(hysteria2_list_forwards "$file")
local IFS=,
echo "${out[*]}"
}

core_hysteria2_role() {
local file="$1"
grep -q '^listen:' "$file" 2>/dev/null && { echo "server"; return; }
grep -q '^server:' "$file" 2>/dev/null && echo "client"
}
core_hysteria2_config_name() {
echo "hysteria2-$(basename "${1%.yaml}")"
}
core_hysteria2_port_number() {
local file="$1" role="$2"
if [[ "$role" == "server" ]]; then
hysteria2_get_listen_port "$file"
else
local addr
addr=$(hysteria2_get_server_addr "$file")
echo "${addr##*:}"
fi
}
core_hysteria2_suggest_free_port() {
local mode="$1" prefix port=36712
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
while [[ -f "${HYSTERIA2_DIR}/${prefix}${port}.yaml" ]] || is_port_listening_system_wide "$port"; do
((port++))
done
echo "$port"
}

core_hysteria2_generate_server_config() {
local output_file="$1" port="$2" password="$3" obfs_password="$4"
core_hysteria2_ensure_cert
{
echo "listen: :${port}"
echo ""
echo "tls:"
echo "  cert: ${CERT_FILE}"
echo "  key: ${KEY_FILE}"
echo ""
echo "auth:"
echo "  type: password"
echo "  password: ${password}"
if [[ -n "$obfs_password" ]]; then
echo ""
echo "obfs:"
echo "  type: salamander"
echo "  salamander:"
echo "    password: ${obfs_password}"
fi
} > "$output_file"
}

core_hysteria2_generate_client_config() {
local output_file="$1" server_addr="$2" password="$3" obfs_password="$4" sni="$5" ports_csv="$6"
{
echo "server: ${server_addr}"
echo ""
echo "auth: ${password}"
echo ""
echo "tls:"
[[ -n "$sni" ]] && echo "  sni: ${sni}"
echo "  insecure: true"
if [[ -n "$obfs_password" ]]; then
echo ""
echo "obfs:"
echo "  type: salamander"
echo "  salamander:"
echo "    password: ${obfs_password}"
fi
local -a entries=()
IFS=',' read -r -a entries <<< "$ports_csv"
local entry listen dest has_tcp="false"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
if [[ "$has_tcp" == "false" ]]; then
echo ""
echo "tcpForwarding:"
has_tcp="true"
fi
echo "  - listen: 0.0.0.0:${listen}"
echo "    remote: 127.0.0.1:${dest}"
done
} > "$output_file"
}

core_hysteria2_create_service() {
local type="$1" port="$2" config_file="$3" mode="$4"
local sub_cmd
[[ "$mode" == "server" ]] && sub_cmd="server" || sub_cmd="client"
local service_file="${service_dir}/hysteria2-${type}${port}.service"
local desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"
cat > "$service_file" <<EOF
[Unit]
Description=Hysteria2 $desc_type Port $port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${HYSTERIA2_BIN} ${sub_cmd} -c ${config_file}
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
systemctl enable --now "hysteria2-${type}${port}.service" >/dev/null 2>&1
}

core_hysteria2_configure() {
local mode="$1"
local existing_config="$2"
local default_ctrl_addr="" default_password="" default_obfs_password="" default_sni="" default_ports="" default_peer_ip="" default_peer_ssh_port="22"
local old_config_name=""
if [[ -n "$existing_config" && -f "$existing_config" ]]; then
if [[ "$mode" == "server" ]]; then
default_ctrl_addr=":$(hysteria2_get_listen_port "$existing_config")"
default_password=$(hysteria2_get_auth_password "$existing_config")
else
default_ctrl_addr=$(hysteria2_get_server_addr "$existing_config")
default_password=$(hysteria2_get_auth_password "$existing_config")
default_sni=$(hysteria2_get_tls_sni "$existing_config")
default_ports=$(hysteria2_forwards_csv "$existing_config")
fi
[[ "$(hysteria2_obfs_enabled "$existing_config")" == "true" ]] && default_obfs_password=$(hysteria2_get_obfs_password "$existing_config")
old_config_name=$(core_hysteria2_config_name "$existing_config")
default_peer_ip=$(read_tunnel_meta "$old_config_name" "peer_ip")
default_peer_ssh_port=$(read_tunnel_meta "$old_config_name" "peer_ssh_port")
[[ -z "$default_peer_ssh_port" ]] && default_peer_ssh_port="22"
fi

clear
colorize cyan "Configuring Hysteria2 $([[ "$mode" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")" bold
echo ""
colorize magenta "Hysteria2 tunnels over QUIC (UDP) with optional obfuscation — useful when the link is filtered or throttled." normal
echo ""

local ctrl_addr password obfs_choice obfs_password sni ports_csv peer_ip peer_ssh_port

if [[ "$mode" == "server" ]]; then
local suggested_port="${default_ctrl_addr#:}"
[[ -z "$suggested_port" ]] && suggested_port=$(core_hysteria2_suggest_free_port "server")
prompt_with_default "Listen Port (UDP)" "$suggested_port" ctrl_addr
[[ -n "$ctrl_addr" && "$ctrl_addr" != *:* ]] && ctrl_addr=":${ctrl_addr}"
else
while true; do
prompt_with_default "IRAN Server Address [IP:Port]" "${default_ctrl_addr:-$(get_last_used "client_remote_addr" "")}" ctrl_addr
[[ -n "$ctrl_addr" && "$ctrl_addr" == *:* ]] && break
colorize red "Invalid format. Use IP:Port."
done
fi

local generated_password
generated_password=$(head -c16 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c20)
prompt_with_default "Auth Password (must match on both sides)" "${default_password:-$generated_password}" password

echo ""
colorize magenta "Obfuscation (Salamander) hides the QUIC handshake pattern from DPI. Recommended if the link is filtered." normal
local obfs_default="true"
[[ -n "$existing_config" ]] && obfs_default="false"
[[ -n "$default_obfs_password" ]] && obfs_default="true"
prompt_boolean "Enable Obfuscation" "$obfs_default" obfs_choice
if [[ "$obfs_choice" == "true" ]]; then
local generated_obfs
generated_obfs=$(head -c16 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c20)
prompt_with_default "Obfuscation Password" "${default_obfs_password:-$generated_obfs}" obfs_password
else
obfs_password=""
fi

if [[ "$mode" == "client" ]]; then
echo ""
prompt_with_default "TLS SNI (domain shown in the handshake, for camouflage)" "${default_sni:-www.digikala.com}" sni
echo ""
colorize green "Supported formats:"
echo "  1. 443           - forward port 443"
echo "  2. 443=5000      - listen on 443, forward to local port 5000"
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
config_path="${HYSTERIA2_DIR}/${config_name}.yaml"

if [[ -f "$config_path" && "$config_name" != "${old_config_name#hysteria2-}" ]]; then
colorize red "A Hysteria2 tunnel already uses port ${ctrl_port} on this side. Choose a different port."
press_key
return 1
fi

if [[ "$mode" == "server" ]]; then
core_hysteria2_generate_server_config "$config_path" "$ctrl_port" "$password" "$obfs_password"
else
core_hysteria2_generate_client_config "$config_path" "$ctrl_addr" "$password" "$obfs_password" "$sni" "$ports_csv"
fi
core_hysteria2_create_service "$prefix" "$ctrl_port" "$config_path" "$mode"

if [[ -n "$old_config_name" && "${old_config_name}" != "hysteria2-${config_name}" ]]; then
local old_service="hysteria2-${old_config_name#hysteria2-}.service"
systemctl disable --now "$old_service" >/dev/null 2>&1
rm -f "${service_dir}/${old_service}"
systemctl daemon-reload
[[ -f "$existing_config" && "$existing_config" != "$config_path" ]] && rm -f "$existing_config"
fi

save_last_used "transport_type" "hysteria2"
[[ "$mode" == "client" ]] && save_last_used "client_remote_addr" "$ctrl_addr"
save_last_used "peer_ip" "$peer_ip"
write_tunnel_meta "hysteria2-${config_name}" "$peer_ip" "${peer_ssh_port:-22}"
ensure_watchdog_installed
ensure_journal_limits
echo ""
colorize green "✔ Hysteria2 configuration completed successfully!" bold
echo ""
core_hysteria2_diagnostics "$config_path"
}

core_hysteria2_configure_tunnel() {
core_hysteria2_ensure_ready
clear
colorize green "1) Configure IRAN (Server)" bold
colorize magenta "2) Configure KHAREJ (Client)" bold
echo ""
read -r -p "Enter your choice: " choice
case "$choice" in
1) core_hysteria2_configure "server" ;;
2) core_hysteria2_configure "client" ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
}

core_hysteria2_diagnostics() {
local config_path="$1"
if [[ ! -f "$config_path" ]]; then
colorize red "Config not found."; press_key; return 1
fi
local config_name role port peer_ip ssh_port service_name my_label peer_label
config_name=$(core_hysteria2_config_name "$config_path")
role=$(core_hysteria2_role "$config_path")
port=$(core_hysteria2_port_number "$config_path" "$role")
service_name="hysteria2-$(basename "${config_path%.yaml}").service"
peer_ip=$(read_tunnel_meta "$config_name" "peer_ip")
ssh_port=$(read_tunnel_meta "$config_name" "peer_ssh_port")
[[ -z "$ssh_port" ]] && ssh_port="22"
if [[ "$role" == "server" ]]; then my_label="IRAN"; peer_label="KHAREJ"; else my_label="KHAREJ"; peer_label="IRAN"; fi

clear
colorize cyan "Tunnel Diagnostics: $(basename "${config_path%.yaml}") (Hysteria2)" bold
echo ""
colorize blue "── ${my_label} side (this server) ──" bold
local ready=1 reason=""
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
ready=0; reason="service ${service_name} is not active"
elif [[ "$role" == "server" ]] && ! is_port_listening_system_wide "$port"; then
ready=0; reason="UDP port ${port} is not bound locally"
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
colorize yellow "Note: Hysteria2's own port (${port}) is UDP/QUIC and can't be reliably probed with a TCP check."
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
IFS=$'\n' read -r -d '' -a ports < <(hysteria2_list_forwards "$config_path" | awk '{print $1}' && printf '\0')
if [[ "${#ports[@]}" -gt 0 && -n "${ports[0]}" ]]; then
if tcp_port_open "$peer_ip" "${ports[0]}" 3; then
colorize green "✔ Forwarded port ${ports[0]} is reachable on ${peer_ip}"
result="ok"
else
colorize red "✘ Services are up but forwarded port ${ports[0]} isn't answering on ${peer_ip} yet."
colorize yellow "Check that both sides use the same auth password (and obfs password, if enabled)."
fi
else
colorize green "✔ Both sides are reachable and services are active."
result="ok"
fi
write_tunnel_last_test "$config_name" "$result"
echo ""
press_key
}

core_hysteria2_benchmark() {
local config_path="$1" config_name role peer_ip port
config_name=$(core_hysteria2_config_name "$config_path")
role=$(core_hysteria2_role "$config_path")
peer_ip=$(read_tunnel_meta "$config_name" "peer_ip")
if [[ -z "$peer_ip" ]]; then
colorize red "Peer IP is not set — set it from the Edit menu first."
press_key
return 1
fi
port=$(core_hysteria2_port_number "$config_path" "$role")
[[ -z "$port" ]] && port=$(read_tunnel_meta "$config_name" "peer_ssh_port")

clear
colorize cyan "Protocol Benchmark — target: ${peer_ip}" bold
colorize yellow "Note: real throughput needs iperf3 running on the peer (iperf3 -s), otherwise it shows N/A."
echo ""
local -A RESULTS
colorize yellow "Testing TCP (SSH port, as a reachability proxy)..."
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

core_hysteria2_edit() {
local config_path="$1" mode
local role
role=$(core_hysteria2_role "$config_path")
[[ "$role" == "server" ]] && mode="server" || mode="client"
local config_name service_name service_path
config_name=$(basename "${config_path%.yaml}")
service_name="hysteria2-${config_name}.service"
service_path="${service_dir}/${service_name}"
local backup_dir
backup_dir=$(backup_tunnel "$config_path" "$service_path" "hysteria2-${config_name}")
colorize green "Current config backed up: $backup_dir"
core_hysteria2_configure "$mode" "$config_path"
local new_service_name
new_service_name="hysteria2-$(basename "${config_path%.yaml}").service"
if [[ ! -f "$config_path" ]]; then
new_service_name="$service_name"
fi
sleep 2
if systemctl is-active --quiet "$new_service_name" 2>/dev/null; then
colorize green "✔ Hysteria2 tunnel is healthy after edit."
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

core_hysteria2_toggle_enabled() {
toggle_tunnel_enabled "$1"
}

core_hysteria2_destroy() {
local config_path="$1"
local silent="${2:-}"
local config_name service_name service_path
config_name=$(basename "${config_path%.yaml}")
service_name="hysteria2-${config_name}.service"
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
colorize green "✔ Removed hysteria2-${config_name}"
fi
}

core_hysteria2_destroy_all() {
local config_path
for config_path in "${HYSTERIA2_DIR}"/{iran,kharej}*.yaml; do
[[ -f "$config_path" ]] || continue
core_hysteria2_destroy "$config_path" --silent
done
}

core_hysteria2_watchdog_check_all() {
local config_path config_name service_name
for config_path in "${HYSTERIA2_DIR}"/{iran,kharej}*.yaml; do
[[ -f "$config_path" ]] || continue
config_name=$(basename "${config_path%.yaml}")
service_name="hysteria2-${config_name}.service"
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
logger -t hysteria2-watchdog "${service_name} is inactive, restarting" 2>/dev/null
systemctl restart "$service_name" 2>/dev/null
fi
done
}

core_hysteria2_detail_page() {
local config_path="$1"
local config_name service_name role port peer_ip last_test last_time
config_name=$(basename "${config_path%.yaml}")
service_name="hysteria2-${config_name}.service"
while true; do
[[ -f "$config_path" ]] || return
role=$(core_hysteria2_role "$config_path")
port=$(core_hysteria2_port_number "$config_path" "$role")
peer_ip=$(read_tunnel_meta "hysteria2-${config_name}" "peer_ip")
clear
colorize cyan "Tunnel: ${config_name} (Hysteria2)" bold
echo ""
if systemctl is-active --quiet "$service_name"; then
colorize green "Status: Active"
else
colorize red "Status: Inactive"
fi
IFS='|' read -r last_test last_time <<< "$(read_tunnel_last_test "hysteria2-${config_name}")"
echo "Last test: ${last_test} (${last_time})"
echo "Tunnel type: hysteria2 / quic"
echo "Role: $([[ "$role" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")"
echo "Port (UDP): ${port}"
echo "Obfuscation: $(hysteria2_obfs_enabled "$config_path")"
if [[ -n "$peer_ip" ]]; then echo "Peer IP: ${peer_ip}"; else echo "Peer IP: not set"; fi
if [[ "$role" == "client" ]]; then
local ports_count
ports_count=$(hysteria2_list_forwards "$config_path" | grep -c .)
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
1) core_hysteria2_edit "$config_path" ;;
2) core_hysteria2_diagnostics "$config_path" ;;
3) core_hysteria2_benchmark "$config_path" ;;
4) view_service_logs "$service_name" ;;
5) view_service_status "$service_name" ;;
6) restart_service "$service_name" ;;
7) core_hysteria2_destroy "$config_path"; return ;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}

core_hysteria2_tunnel_management() {
if ! ls "${HYSTERIA2_DIR}"/*.yaml 1> /dev/null 2>&1; then
colorize red "No Hysteria2 config files found." bold
press_key
return 1
fi
clear
colorize cyan "Existing Hysteria2 services:" bold
echo
local index=1 config_path config_name port
local -a configs=()
for config_path in "${HYSTERIA2_DIR}"/{iran,kharej}*.yaml; do
[ -f "$config_path" ] || continue
config_name=$(basename "$config_path")
if [[ "$config_name" =~ ^iran([0-9]+)\.yaml$ ]]; then
port="${BASH_REMATCH[1]}"
configs+=("$config_path")
echo -e "\033[35m${index}\033[0m) \033[32mIran\033[0m (port: \033[33m$port\033[0m)"
((index++))
elif [[ "$config_name" =~ ^kharej([0-9]+)\.yaml$ ]]; then
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
core_hysteria2_detail_page "${configs[$((choice - 1))]}"
}

core_hysteria2_check_status() {
if ! ls "${HYSTERIA2_DIR}"/*.yaml 1> /dev/null 2>&1; then
colorize red "No Hysteria2 config files found." bold
press_key
return 1
fi
clear
colorize yellow "Checking all Hysteria2 services status..." bold
sleep 1
echo
local config_path config_name service_name port
for config_path in "${HYSTERIA2_DIR}"/{iran,kharej}*.yaml; do
[ -f "$config_path" ] || continue
config_name=$(basename "$config_path")
config_name="${config_name%.yaml}"
service_name="hysteria2-${config_name}.service"
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

core_hysteria2_menu() {
core_hysteria2_ensure_ready
while true; do
clear
colorize cyan "Hysteria2" bold
echo ""
colorize green " 1. Configure a new tunnel" bold
colorize red " 2. Tunnel management" bold
colorize cyan " 3. Check tunnel status" bold
echo " 4. Update Hysteria2 core"
echo " 0. Back"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Enter your choice [0-4]: " choice
case "$choice" in
1) core_hysteria2_configure_tunnel ;;
2) core_hysteria2_tunnel_management ;;
3) core_hysteria2_check_status ;;
4) core_hysteria2_update ;;
0) return ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
done
}

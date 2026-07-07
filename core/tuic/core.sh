#!/usr/bin/env bash
# TUIC tunnel core. Mirrors Hysteria2's workflow (both are QUIC/UDP proxy
# protocols with client-side local-forward config) but ships two separate
# binaries like FRP (tuic-server / tuic-client) and uses UUID+password auth
# instead of a single shared token.
#
# Upstream note: the original EAimTY/tuic project is inactive; tuic-protocol/
# tuic (the current org) is now just the protocol spec, and its own GitHub
# releases are split into independently-versioned tuic-server-X / tuic-
# client-X tags with no combined binary release. This core installs from
# github.com/Itsusinn/tuic instead — the actively maintained implementation
# tuic-protocol/tuic's own README lists as a reference implementation, and
# the only one publishing current server+client binaries together in one
# release. That repo does not publish checksums for its releases, so
# core_tuic_install has nothing to verify against beyond TLS — same
# "warn and proceed" fallback the other cores use when a checksum is
# unavailable, just always taken here rather than as a fallback.
#
# Requires lib/common.sh and core/backhaul/core.sh to already be sourced
# (shared write_tunnel_meta/read_tunnel_meta/write_tunnel_last_test/
# read_tunnel_last_test/ensure_watchdog_installed helpers, same layering
# Rathole/Hysteria2/FRP already rely on).
#
# Layout: ${config_dir}/tuic/{tuic_server_bin,tuic_client_bin}, .../iranN.toml
# (server), .../kharejN.toml (client). Services: tuic-iranN.service /
# tuic-kharejN.service. Config identity prefixed "tuic-".
#
# Generated TOML uses bracketed [section] tables (verified against the real
# tuic-server/tuic-client config.rs source, not guessed) so toml_get() can
# read scalar fields back; [[local.tcp_forward]] is an array-of-tables like
# Hysteria2's tcpForwarding and FRP's [[proxies]], so it gets its own
# awk-based getter below, same approach as those two.
#
# Port-forwarding direction matches Hysteria2, not FRP: [[local.tcp_forward]]
# lives in the CLIENT (KHAREJ) config, "listen" is where the client itself
# listens, "remote" is an address reachable from the SERVER (IRAN) side. So
# the "Ports to forward" prompt lives on the KHAREJ side here, same as
# Hysteria2, not IRAN like Backhaul/Rathole/FRP.
#
# The client always sets `skip_cert_verify = true` for the same reason
# Hysteria2 sets `insecure: true`: Iran and Kharej are separate servers with
# separate panel installs, so there's no in-panel channel to move a cert
# fingerprint from one to the other automatically. The real trust boundary
# is the UUID+password pair, not certificate identity.

TUIC_REPO="Itsusinn/tuic"
TUIC_DIR="${config_dir}/tuic"
TUIC_SERVER_BIN="${TUIC_DIR}/tuic_server_bin"
TUIC_CLIENT_BIN="${TUIC_DIR}/tuic_client_bin"

core_tuic_ensure_ready() {
mkdir -p "$TUIC_DIR"
core_tuic_install
}

core_tuic_install() {
[[ -f "$TUIC_SERVER_BIN" && -f "$TUIC_CLIENT_BIN" ]] && return 0
core_tuic_download_binaries
}

tuic_generate_uuid() {
if [[ -r /proc/sys/kernel/random/uuid ]]; then
cat /proc/sys/kernel/random/uuid
elif command -v uuidgen &> /dev/null; then
uuidgen
else
printf '%08x-%04x-%04x-%04x-%012x\n' \
"$((RANDOM * RANDOM))" "$((RANDOM % 65536))" "$(((RANDOM % 4096) | 0x4000))" "$(((RANDOM % 16384) | 0x8000))" "$((RANDOM * RANDOM * RANDOM))"
fi
}

core_tuic_download_binaries() {
mkdir -p "$TUIC_DIR"
colorize yellow "Installing TUIC..."
local arch asset_arch
arch=$(uname -m)
case "$arch" in
x86_64) asset_arch="x86_64" ;;
aarch64|arm64) asset_arch="aarch64" ;;
*)
colorize red "Unsupported architecture for TUIC: ${arch}."
press_key
return 1
;;
esac
local latest_url tag
latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${TUIC_REPO}/releases/latest" 2>/dev/null)
tag="${latest_url##*/}"
if [[ -z "$tag" ]]; then
colorize red "Could not determine the latest TUIC release."
press_key
return 1
fi
local server_url="https://github.com/${TUIC_REPO}/releases/download/${tag}/tuic-server-${asset_arch}-linux"
local client_url="https://github.com/${TUIC_REPO}/releases/download/${tag}/tuic-client-${asset_arch}-linux"
local tmp_dir
tmp_dir=$(mktemp -d)
if ! curl -fsSL "$server_url" -o "${tmp_dir}/tuic-server"; then
colorize red "Download failed: ${server_url}"
rm -rf "$tmp_dir"
press_key
return 1
fi
if ! curl -fsSL "$client_url" -o "${tmp_dir}/tuic-client"; then
colorize red "Download failed: ${client_url}"
rm -rf "$tmp_dir"
press_key
return 1
fi
colorize yellow "Note: upstream does not publish checksums for this release; installing unverified over HTTPS."
chmod +x "${tmp_dir}/tuic-server" "${tmp_dir}/tuic-client"
if ! "${tmp_dir}/tuic-server" --help &> /dev/null || ! "${tmp_dir}/tuic-client" --help &> /dev/null; then
colorize red "Downloaded TUIC binaries failed a basic sanity check (--help)."
rm -rf "$tmp_dir"
press_key
return 1
fi
local tmp_s tmp_c
tmp_s=$(mktemp "${TUIC_DIR}/.tuic_server_bin.XXXXXX")
tmp_c=$(mktemp "${TUIC_DIR}/.tuic_client_bin.XXXXXX")
cp "${tmp_dir}/tuic-server" "$tmp_s"
cp "${tmp_dir}/tuic-client" "$tmp_c"
chmod +x "$tmp_s" "$tmp_c"
mv -f "$tmp_s" "$TUIC_SERVER_BIN"
mv -f "$tmp_c" "$TUIC_CLIENT_BIN"
rm -rf "$tmp_dir"
colorize green "✔ TUIC ${tag} installed."
}

core_tuic_update() {
colorize yellow "Checking for a newer TUIC core..."
local backup_s="" backup_c=""
if [[ -f "$TUIC_SERVER_BIN" ]]; then
backup_s=$(mktemp "${TUIC_DIR}/.tuic_server_bin_backup.XXXXXX")
cp "$TUIC_SERVER_BIN" "$backup_s"
fi
if [[ -f "$TUIC_CLIENT_BIN" ]]; then
backup_c=$(mktemp "${TUIC_DIR}/.tuic_client_bin_backup.XXXXXX")
cp "$TUIC_CLIENT_BIN" "$backup_c"
fi
if ! core_tuic_download_binaries; then
[[ -n "$backup_s" ]] && mv -f "$backup_s" "$TUIC_SERVER_BIN"
[[ -n "$backup_c" ]] && mv -f "$backup_c" "$TUIC_CLIENT_BIN"
[[ -n "$backup_s$backup_c" ]] && colorize yellow "Restored the previous core."
return 1
fi
if ! "$TUIC_SERVER_BIN" --help &> /dev/null || ! "$TUIC_CLIENT_BIN" --help &> /dev/null; then
colorize red "New core failed a basic sanity check."
[[ -n "$backup_s" ]] && mv -f "$backup_s" "$TUIC_SERVER_BIN"
[[ -n "$backup_c" ]] && mv -f "$backup_c" "$TUIC_CLIENT_BIN"
colorize yellow "Restored the previous core."
press_key
return 1
fi
[[ -n "$backup_s" ]] && rm -f "$backup_s"
[[ -n "$backup_c" ]] && rm -f "$backup_c"
press_key
}

core_tuic_ensure_cert() {
if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
colorize yellow "[*] TLS certificate or key missing, generating self-signed Ed25519 cert..."
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 -days 365 -sha256 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=backhaul.com"
colorize green "[*] Generated $CERT_FILE and $KEY_FILE"
fi
}

# ── TOML getters (server/uuid/password/skip_cert_verify are plain scalars
# under a real [section], so toml_get() handles them; [[local.tcp_forward]]
# is an array-of-tables and gets its own awk getter, same as Hysteria2's
# tcpForwarding / FRP's [[proxies]]. ──

tuic_get_listen_addr() {
# Server's own line is always the fixed "server = "[::]:PORT"" shape this
# core generates, so the port is the only run of digits on the line.
grep '^server = ' "$1" 2>/dev/null | head -1 | grep -oE '[0-9]+' | tail -1
}
tuic_get_users_uuid_password() {
awk '
FNR==1 { insec=0 }
/^\[/ { insec = ($0 == "[users]") }
insec && /=/ {
line = $0
sub(/^[ \t]*/, "", line)
n = index(line, "=")
u = substr(line, 1, n-1)
gsub(/[ \t]*$/, "", u)
v = substr(line, n+1)
gsub(/^[ \t]*"/, "", v)
gsub(/"[ \t]*$/, "", v)
print u, v
exit
}
' "$1" 2>/dev/null
}
tuic_get_relay_server_addr() {
grep '^server = ' "$1" 2>/dev/null | head -1 | sed -E 's/^server = "([^"]*)".*/\1/'
}
tuic_get_relay_sni() {
grep '^sni = ' "$1" 2>/dev/null | head -1 | sed -E 's/^sni = "([^"]*)".*/\1/'
}
tuic_list_forwards() {
awk '
/^\[\[local\.tcp_forward\]\]/ { in_fwd=1; next }
/^\[/ { in_fwd=0 }
in_fwd && /^listen = / { match($0, /:[0-9]+"/); l=substr($0, RSTART+1, RLENGTH-2) }
in_fwd && /^remote = / { match($0, /:[0-9]+"/); r=substr($0, RSTART+1, RLENGTH-2); print l, r }
' "$1" 2>/dev/null
}
tuic_forwards_csv() {
local file="$1" listen remote
local -a out=()
while read -r listen remote; do
[[ -z "$listen" ]] && continue
if [[ "$listen" == "$remote" ]]; then out+=("$listen"); else out+=("${listen}=${remote}"); fi
done < <(tuic_list_forwards "$file")
local IFS=,
echo "${out[*]}"
}

core_tuic_role() {
local file="$1"
grep -q '^\[users\]' "$file" 2>/dev/null && { echo "server"; return; }
grep -q '^\[relay\]' "$file" 2>/dev/null && echo "client"
}
core_tuic_config_name() {
echo "tuic-$(basename "${1%.toml}")"
}
core_tuic_port_number() {
local file="$1" role="$2"
if [[ "$role" == "server" ]]; then
tuic_get_listen_addr "$file"
else
local addr
addr=$(tuic_get_relay_server_addr "$file")
echo "${addr##*:}"
fi
}
core_tuic_suggest_free_port() {
local mode="$1" prefix port=443
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
[[ "$mode" == "server" ]] && port=44300
while [[ -f "${TUIC_DIR}/${prefix}${port}.toml" ]] || is_port_listening_system_wide "$port"; do
((port++))
done
echo "$port"
}

core_tuic_generate_server_config() {
local output_file="$1" port="$2" uuid="$3" password="$4"
core_tuic_ensure_cert
{
echo "log_level = \"info\""
echo "server = \"[::]:${port}\""
echo ""
echo "[users]"
echo "${uuid} = \"${password}\""
echo ""
echo "[tls]"
echo "self_sign = false"
echo "certificate = \"${CERT_FILE}\""
echo "private_key = \"${KEY_FILE}\""
echo "alpn = [\"h3\"]"
} > "$output_file"
}

core_tuic_generate_client_config() {
local output_file="$1" server_addr="$2" uuid="$3" password="$4" sni="$5" ports_csv="$6"
{
echo "[relay]"
echo "server = \"${server_addr}\""
echo "uuid = \"${uuid}\""
echo "password = \"${password}\""
echo "congestion_control = \"bbr\""
[[ -n "$sni" ]] && echo "sni = \"${sni}\""
echo "skip_cert_verify = true"
echo "alpn = [\"h3\"]"
local -a entries=()
IFS=',' read -r -a entries <<< "$ports_csv"
local entry listen dest
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
echo ""
echo "[[local.tcp_forward]]"
echo "listen = \"0.0.0.0:${listen}\""
echo "remote = \"127.0.0.1:${dest}\""
done
} > "$output_file"
}

core_tuic_create_service() {
local type="$1" port="$2" config_file="$3" mode="$4"
local bin sub_desc
if [[ "$mode" == "server" ]]; then bin="$TUIC_SERVER_BIN"; sub_desc="tuic-server"; else bin="$TUIC_CLIENT_BIN"; sub_desc="tuic-client"; fi
local service_file="${service_dir}/tuic-${type}${port}.service"
local desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"
cat > "$service_file" <<EOF
[Unit]
Description=TUIC (${sub_desc}) $desc_type Port $port
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
systemctl enable --now "tuic-${type}${port}.service" >/dev/null 2>&1
}

core_tuic_configure() {
local mode="$1"
local existing_config="$2"
local default_ctrl_addr="" default_uuid="" default_password="" default_sni="" default_ports="" default_peer_ip="" default_peer_ssh_port="22"
local old_config_name=""
if [[ -n "$existing_config" && -f "$existing_config" ]]; then
if [[ "$mode" == "server" ]]; then
default_ctrl_addr=":$(tuic_get_listen_addr "$existing_config")"
read -r default_uuid default_password <<< "$(tuic_get_users_uuid_password "$existing_config")"
else
default_ctrl_addr=$(tuic_get_relay_server_addr "$existing_config")
default_uuid=$(grep '^uuid = ' "$existing_config" 2>/dev/null | head -1 | sed -E 's/^uuid = "([^"]*)".*/\1/')
default_password=$(grep '^password = ' "$existing_config" 2>/dev/null | head -1 | sed -E 's/^password = "([^"]*)".*/\1/')
default_sni=$(tuic_get_relay_sni "$existing_config")
default_ports=$(tuic_forwards_csv "$existing_config")
fi
old_config_name=$(core_tuic_config_name "$existing_config")
default_peer_ip=$(read_tunnel_meta "$old_config_name" "peer_ip")
default_peer_ssh_port=$(read_tunnel_meta "$old_config_name" "peer_ssh_port")
[[ -z "$default_peer_ssh_port" ]] && default_peer_ssh_port="22"
fi

clear
colorize cyan "Configuring TUIC $([[ "$mode" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")" bold
echo ""
colorize magenta "TUIC tunnels over QUIC (UDP), like Hysteria2 — a lightweight alternative worth trying if one link works better with it than the other." normal
echo ""

local ctrl_addr uuid password sni ports_csv peer_ip peer_ssh_port

if [[ "$mode" == "server" ]]; then
local suggested_port="${default_ctrl_addr#:}"
[[ -z "$suggested_port" ]] && suggested_port=$(core_tuic_suggest_free_port "server")
prompt_with_default "Listen Port (UDP)" "$suggested_port" ctrl_addr
[[ -n "$ctrl_addr" && "$ctrl_addr" != *:* ]] && ctrl_addr=":${ctrl_addr}"
else
while true; do
prompt_with_default "IRAN Server Address [IP:Port]" "${default_ctrl_addr:-$(get_last_used "client_remote_addr" "")}" ctrl_addr
[[ -n "$ctrl_addr" && "$ctrl_addr" == *:* ]] && break
colorize red "Invalid format. Use IP:Port."
done
fi

local generated_uuid generated_password
generated_uuid=$(tuic_generate_uuid)
generated_password=$(head -c16 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c20)
prompt_with_default "User UUID (must match on both sides)" "${default_uuid:-$generated_uuid}" uuid
prompt_with_default "Password (must match on both sides)" "${default_password:-$generated_password}" password

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
config_path="${TUIC_DIR}/${config_name}.toml"

if [[ -f "$config_path" && "$config_name" != "${old_config_name#tuic-}" ]]; then
colorize red "A TUIC tunnel already uses port ${ctrl_port} on this side. Choose a different port."
press_key
return 1
fi

if [[ "$mode" == "server" ]]; then
core_tuic_generate_server_config "$config_path" "$ctrl_port" "$uuid" "$password"
else
core_tuic_generate_client_config "$config_path" "$ctrl_addr" "$uuid" "$password" "$sni" "$ports_csv"
fi
core_tuic_create_service "$prefix" "$ctrl_port" "$config_path" "$mode"

if [[ -n "$old_config_name" && "${old_config_name}" != "tuic-${config_name}" ]]; then
local old_service="tuic-${old_config_name#tuic-}.service"
systemctl disable --now "$old_service" >/dev/null 2>&1
rm -f "${service_dir}/${old_service}"
systemctl daemon-reload
[[ -f "$existing_config" && "$existing_config" != "$config_path" ]] && rm -f "$existing_config"
fi

save_last_used "transport_type" "tuic"
[[ "$mode" == "client" ]] && save_last_used "client_remote_addr" "$ctrl_addr"
save_last_used "peer_ip" "$peer_ip"
write_tunnel_meta "tuic-${config_name}" "$peer_ip" "${peer_ssh_port:-22}"
ensure_watchdog_installed
ensure_journal_limits
echo ""
colorize green "✔ TUIC configuration completed successfully!" bold
echo ""
core_tuic_diagnostics "$config_path"
}

core_tuic_configure_tunnel() {
core_tuic_ensure_ready
clear
colorize green "1) Configure IRAN (Server)" bold
colorize magenta "2) Configure KHAREJ (Client)" bold
echo ""
read -r -p "Enter your choice: " choice
case "$choice" in
1) core_tuic_configure "server" ;;
2) core_tuic_configure "client" ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
}

core_tuic_diagnostics() {
local config_path="$1"
if [[ ! -f "$config_path" ]]; then
colorize red "Config not found."; press_key; return 1
fi
local config_name role port peer_ip ssh_port service_name my_label peer_label
config_name=$(core_tuic_config_name "$config_path")
role=$(core_tuic_role "$config_path")
port=$(core_tuic_port_number "$config_path" "$role")
service_name="tuic-$(basename "${config_path%.toml}").service"
peer_ip=$(read_tunnel_meta "$config_name" "peer_ip")
ssh_port=$(read_tunnel_meta "$config_name" "peer_ssh_port")
[[ -z "$ssh_port" ]] && ssh_port="22"
if [[ "$role" == "server" ]]; then my_label="IRAN"; peer_label="KHAREJ"; else my_label="KHAREJ"; peer_label="IRAN"; fi

clear
colorize cyan "Tunnel Diagnostics: $(basename "${config_path%.toml}") (TUIC)" bold
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
colorize yellow "Note: TUIC's own port (${port}) is UDP/QUIC and can't be reliably probed with a TCP check."
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
IFS=$'\n' read -r -d '' -a ports < <(tuic_list_forwards "$config_path" | awk '{print $1}' && printf '\0')
if [[ "${#ports[@]}" -gt 0 && -n "${ports[0]}" ]]; then
if tcp_port_open "$peer_ip" "${ports[0]}" 3; then
colorize green "✔ Forwarded port ${ports[0]} is reachable on ${peer_ip}"
result="ok"
else
colorize red "✘ Services are up but forwarded port ${ports[0]} isn't answering on ${peer_ip} yet."
colorize yellow "Check that both sides use the same UUID and password."
fi
else
colorize green "✔ Both sides are reachable and services are active."
result="ok"
fi
write_tunnel_last_test "$config_name" "$result"
echo ""
press_key
}

core_tuic_benchmark() {
local config_path="$1" config_name role peer_ip port
config_name=$(core_tuic_config_name "$config_path")
role=$(core_tuic_role "$config_path")
peer_ip=$(read_tunnel_meta "$config_name" "peer_ip")
if [[ -z "$peer_ip" ]]; then
colorize red "Peer IP is not set — set it from the Edit menu first."
press_key
return 1
fi
port=$(core_tuic_port_number "$config_path" "$role")
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

core_tuic_edit() {
local config_path="$1" mode
local role
role=$(core_tuic_role "$config_path")
[[ "$role" == "server" ]] && mode="server" || mode="client"
local config_name service_name service_path
config_name=$(basename "${config_path%.toml}")
service_name="tuic-${config_name}.service"
service_path="${service_dir}/${service_name}"
local backup_dir
backup_dir=$(backup_tunnel "$config_path" "$service_path" "tuic-${config_name}")
colorize green "Current config backed up: $backup_dir"
core_tuic_configure "$mode" "$config_path"
local new_service_name
new_service_name="tuic-$(basename "${config_path%.toml}").service"
if [[ ! -f "$config_path" ]]; then
new_service_name="$service_name"
fi
sleep 2
if systemctl is-active --quiet "$new_service_name" 2>/dev/null; then
colorize green "✔ TUIC tunnel is healthy after edit."
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

core_tuic_toggle_enabled() {
toggle_tunnel_enabled "$1"
}

core_tuic_destroy() {
local config_path="$1"
local silent="${2:-}"
local config_name service_name service_path
config_name=$(basename "${config_path%.toml}")
service_name="tuic-${config_name}.service"
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
colorize green "✔ Removed tuic-${config_name}"
fi
}

core_tuic_destroy_all() {
local config_path
for config_path in "${TUIC_DIR}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
core_tuic_destroy "$config_path" --silent
done
}

core_tuic_watchdog_check_all() {
local config_path config_name service_name
for config_path in "${TUIC_DIR}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
config_name=$(basename "${config_path%.toml}")
service_name="tuic-${config_name}.service"
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
logger -t tuic-watchdog "${service_name} is inactive, restarting" 2>/dev/null
systemctl restart "$service_name" 2>/dev/null
fi
done
}

core_tuic_detail_page() {
local config_path="$1"
local config_name service_name role port peer_ip last_test last_time
config_name=$(basename "${config_path%.toml}")
service_name="tuic-${config_name}.service"
while true; do
[[ -f "$config_path" ]] || return
role=$(core_tuic_role "$config_path")
port=$(core_tuic_port_number "$config_path" "$role")
peer_ip=$(read_tunnel_meta "tuic-${config_name}" "peer_ip")
clear
colorize cyan "Tunnel: ${config_name} (TUIC)" bold
echo ""
if systemctl is-active --quiet "$service_name"; then
colorize green "Status: Active"
else
colorize red "Status: Inactive"
fi
IFS='|' read -r last_test last_time <<< "$(read_tunnel_last_test "tuic-${config_name}")"
echo "Last test: ${last_test} (${last_time})"
echo "Tunnel type: tuic / quic"
echo "Role: $([[ "$role" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")"
echo "Port (UDP): ${port}"
if [[ -n "$peer_ip" ]]; then echo "Peer IP: ${peer_ip}"; else echo "Peer IP: not set"; fi
if [[ "$role" == "client" ]]; then
local ports_count
ports_count=$(tuic_list_forwards "$config_path" | grep -c .)
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
1) core_tuic_edit "$config_path" ;;
2) core_tuic_diagnostics "$config_path" ;;
3) core_tuic_benchmark "$config_path" ;;
4) view_service_logs "$service_name" ;;
5) view_service_status "$service_name" ;;
6) restart_service "$service_name" ;;
7) core_tuic_destroy "$config_path"; return ;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}

core_tuic_tunnel_management() {
if ! ls "${TUIC_DIR}"/*.toml 1> /dev/null 2>&1; then
colorize red "No TUIC config files found." bold
press_key
return 1
fi
clear
colorize cyan "Existing TUIC services:" bold
echo
local index=1 config_path config_name port
local -a configs=()
for config_path in "${TUIC_DIR}"/{iran,kharej}*.toml; do
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
core_tuic_detail_page "${configs[$((choice - 1))]}"
}

core_tuic_check_status() {
if ! ls "${TUIC_DIR}"/*.toml 1> /dev/null 2>&1; then
colorize red "No TUIC config files found." bold
press_key
return 1
fi
clear
colorize yellow "Checking all TUIC services status..." bold
sleep 1
echo
local config_path config_name service_name port
for config_path in "${TUIC_DIR}"/{iran,kharej}*.toml; do
[ -f "$config_path" ] || continue
config_name=$(basename "$config_path")
config_name="${config_name%.toml}"
service_name="tuic-${config_name}.service"
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

core_tuic_menu() {
core_tuic_ensure_ready
while true; do
clear
colorize cyan "TUIC" bold
echo ""
colorize green " 1. Configure a new tunnel" bold
colorize red " 2. Tunnel management" bold
colorize cyan " 3. Check tunnel status" bold
echo " 4. Update TUIC core"
echo " 0. Back"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Enter your choice [0-4]: " choice
case "$choice" in
1) core_tuic_configure_tunnel ;;
2) core_tuic_tunnel_management ;;
3) core_tuic_check_status ;;
4) core_tuic_update ;;
0) return ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
done
}

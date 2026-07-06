#!/usr/bin/env bash
SCRIPT_VERSION="v1.0.0"
SCRIPT_MODE="$1"
PANEL_PATH="/usr/local/bin/backhaul"
service_dir="/etc/systemd/system"
config_dir="/root/backhaul-core"
CERT_DIR="/root/backhaul-core/cert_files"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/cert.key"
mkdir -p "$CERT_DIR"
if [[ $EUID -ne 0 ]]; then
echo "This script must be run as root"
sleep 1
exit 1
fi
colorize() {
local color="$1"
local text="$2"
local style="${3:-normal}"
local black="\033[30m" red="\033[31m" green="\033[32m" yellow="\033[33m"
local blue="\033[34m" magenta="\033[35m" cyan="\033[36m" white="\033[37m"
local reset="\033[0m" normal="\033[0m" bold="\033[1m" underline="\033[4m"
local color_code
case $color in
black) color_code=$black ;; red) color_code=$red ;;
green) color_code=$green ;; yellow) color_code=$yellow ;;
blue) color_code=$blue ;; magenta) color_code=$magenta ;;
cyan) color_code=$cyan ;; white) color_code=$white ;;
*) color_code=$reset ;;
esac
local style_code
case $style in
bold) style_code=$bold ;; underline) style_code=$underline ;;
normal | *) style_code=$normal ;;
esac
echo -e "${style_code}${color_code}${text}${reset}"
}
press_key() {
read -r -p "Press any key to continue..."
}
prompt_with_default() {
local prompt="$1"
local default="$2"
local var_name="$3"
local input
echo -ne "[-] $prompt (default: $default): "
read -r input
eval "$var_name=\"${input:-$default}\""
}
prompt_boolean() {
local prompt="$1"
local default="$2"
local var_name="$3"
while true; do
prompt_with_default "$prompt [true/false]" "$default" "$var_name"
local value="${!var_name}"
if [[ "$value" == "true" || "$value" == "false" ]]; then
break
fi
colorize red "Invalid input. Please enter 'true' or 'false'."
done
}
validate_cidr() {
local cidr="$1"
if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
return 1
fi
IFS='/' read -r ip mask <<< "$cidr"
IFS='.' read -r a b c d <<< "$ip"
a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d)); mask=$((10#$mask))
if (( a<0 || a>255 || b<0 || b>255 || c<0 || c>255 || d<0 || d>255 )); then
return 1
fi
if (( mask < 1 || mask > 32 )); then
return 1
fi
local ip_int=$(( (a << 24) | (b << 16) | (c << 8) | d ))
local mask_int
if (( mask == 32 )); then
mask_int=0xFFFFFFFF
else
mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
fi
local net_int=$(( ip_int & mask_int ))
local broadcast_int=$(( net_int | (~mask_int & 0xFFFFFFFF) ))
if (( ip_int == net_int )); then
return 1
fi
if (( ip_int == broadcast_int )); then
return 1
fi
return 0
}
cidr_range() {
local cidr="$1"
local ip="${cidr%/*}"
local mask="${cidr#*/}"
local a b c d
IFS='.' read -r a b c d <<< "$ip"
a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d)); mask=$((10#$mask))
local ip_int=$(( (a << 24) | (b << 16) | (c << 8) | d ))
local mask_int
if (( mask == 0 )); then
mask_int=0
else
mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
fi
local net_int=$(( ip_int & mask_int ))
local broadcast_int=$(( net_int | (~mask_int & 0xFFFFFFFF) ))
echo "$net_int $broadcast_int"
}
cidr_overlaps() {
local net1 bcast1 net2 bcast2
read -r net1 bcast1 <<< "$(cidr_range "$1")"
read -r net2 bcast2 <<< "$(cidr_range "$2")"
(( net1 <= bcast2 && net2 <= bcast1 ))
}
existing_tun_cidrs() {
awk '
FNR==1 { in_tun=0 }
/^\[/ { in_tun = ($0 == "[tun]") }
in_tun && /^(local_addr|remote_addr) = "/ {
if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)
}
' "${config_dir}"/*.toml 2>/dev/null
}
toml_tun_name() {
local file="$1"
awk '
FNR==1 { in_tun=0 }
/^\[/ { in_tun = ($0 == "[tun]") }
in_tun && /^name = "/ {
if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)
}
' "$file" 2>/dev/null
}
toml_ipx_profile() {
local file="$1"
awk '
FNR==1 { in_ipx=0 }
/^\[/ { in_ipx = ($0 == "[ipx]") }
in_ipx && /^profile = "/ {
if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2)
}
' "$file" 2>/dev/null
}
has_any_tun_config() {
grep -l '^\[tun\]$' "${config_dir}"/*.toml 2>/dev/null | grep -q .
}
profile_still_in_use() {
local profile="$1"
local f
for f in "${config_dir}"/*.toml; do
[[ -f "$f" ]] || continue
[[ "$(toml_ipx_profile "$f")" == "$profile" ]] && return 0
done
return 1
}
is_tun_subnet_in_use() {
local cidr="$1"
local existing
while IFS= read -r existing; do
[[ -z "$existing" ]] && continue
if cidr_overlaps "$cidr" "$existing"; then
return 0
fi
done <<< "$(existing_tun_cidrs)"
return 1
}
suggest_tun_subnet_third_octet() {
local used
used=$(existing_tun_cidrs | grep -oE '^10\.10\.[0-9]{1,3}\.' | cut -d. -f3)
local third=10
while grep -qx "$third" <<< "$used"; do
((third++))
done
echo "$third"
}
is_tun_name_in_use() {
local name="$1"
grep -qxF "name = \"${name}\"" "${config_dir}"/*.toml 2>/dev/null
}
is_tunnel_port_in_use() {
local mode="$1"
local port="$2"
local prefix
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
[[ -f "${config_dir}/${prefix}${port}.toml" ]]
}
suggest_free_tunnel_port() {
local mode="$1"
local prefix
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
local port=1234
while [[ -f "${config_dir}/${prefix}${port}.toml" ]]; do
((port++))
done
echo "$port"
}
is_valid_tun_name() {
local name="$1"
[[ "$name" =~ ^[A-Za-z0-9_-]{1,15}$ ]]
}
suggest_tun_name() {
local base="backhaul"
local used
used=$(grep -h -oE '^name = "[^"]*"' "${config_dir}"/*.toml 2>/dev/null | sed -E 's/^name = "(.*)"$/\1/')
local candidate="$base"
local n=1
while grep -qx "$candidate" <<< "$used"; do
((n++))
candidate="${base}${n}"
done
echo "$candidate"
}
detect_default_interface() {
local iface
iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
if [[ -z "$iface" ]]; then
iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
fi
echo "$iface"
}
persist_line_once() {
local line="$1"
local file="$2"
mkdir -p "$(dirname "$file")"
touch "$file"
grep -qxF "$line" "$file" || echo "$line" >> "$file"
}
prepare_tun_ipx_kernel() {
local is_ipx="$1"
local profile="$2"
local tun_name="$3"
colorize yellow "Applying kernel prerequisites for TUN..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1
persist_line_once "net.ipv4.ip_forward=1" "/etc/sysctl.d/99-backhaul-tunnel.conf"
persist_line_once "net.ipv4.conf.all.rp_filter=0" "/etc/sysctl.d/99-backhaul-tunnel.conf"
persist_line_once "net.ipv4.conf.default.rp_filter=0" "/etc/sysctl.d/99-backhaul-tunnel.conf"
local rp_file
for rp_file in /proc/sys/net/ipv4/conf/*/rp_filter; do
{ echo 0 > "$rp_file"; } 2>/dev/null
done
sysctl -p /etc/sysctl.d/99-backhaul-tunnel.conf >/dev/null 2>&1
if command -v iptables &> /dev/null && [[ -n "$tun_name" ]]; then
local forward_changed="false"
if ! iptables -C FORWARD -i "$tun_name" -j ACCEPT 2>/dev/null; then
iptables -I FORWARD -i "$tun_name" -j ACCEPT
forward_changed="true"
fi
if ! iptables -C FORWARD -o "$tun_name" -j ACCEPT 2>/dev/null; then
iptables -I FORWARD -o "$tun_name" -j ACCEPT
forward_changed="true"
fi
[[ "$forward_changed" == "true" ]] && persist_iptables_rules
fi
if [[ "$is_ipx" == "true" ]]; then
local mod=""
case "$profile" in
gre) mod="ip_gre" ;;
ipip) mod="ipip" ;;
esac
if [[ -n "$mod" ]] && command -v modprobe &> /dev/null; then
lsmod | grep -qw "$mod" || modprobe "$mod" >/dev/null 2>&1
persist_line_once "$mod" "/etc/modules-load.d/backhaul-tunnel.conf"
fi
fi
colorize green "Kernel prerequisites applied."
}
persist_iptables_rules() {
if command -v netfilter-persistent &> /dev/null; then
netfilter-persistent save >/dev/null 2>&1
elif command -v iptables-save &> /dev/null && [[ -d /etc/iptables ]]; then
iptables-save > /etc/iptables/rules.v4 2>/dev/null
else
colorize yellow "Note: this iptables rule is not persisted across reboot (install iptables-persistent to persist)."
fi
}
allow_forwarded_ports_firewall() {
local mapping="$1" accept_udp="$2" entry listen proto
local -a protos=(tcp)
[[ "$accept_udp" == "true" ]] && protos+=(udp)
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
local changed="false"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
listen="${entry%%[=:]*}"
listen="${listen//-/:}"
[[ -z "$listen" ]] && continue
for proto in "${protos[@]}"; do
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
ufw allow "${listen}/${proto}" >/dev/null 2>&1
elif command -v iptables &> /dev/null; then
if ! iptables -C INPUT -p "$proto" --dport "$listen" -j ACCEPT 2>/dev/null; then
iptables -I INPUT -p "$proto" --dport "$listen" -j ACCEPT
changed="true"
fi
fi
done
done
[[ "$changed" == "true" ]] && command -v iptables &> /dev/null && persist_iptables_rules
}
parse_port_entry() {
local entry="$1" listen dest
if [[ "$entry" == *=* ]]; then
listen="${entry%%=*}"; dest="${entry#*=}"
elif [[ "$entry" == *:* ]]; then
listen="${entry%%:*}"; dest="${entry#*:}"
else
listen="$entry"; dest="$entry"
fi
listen="${listen//-/:}"
dest="${dest//-/:}"
echo "$listen $dest"
}
ensure_tun_masquerade() {
local tun_name="$1"
command -v iptables &> /dev/null || return
if ! iptables -t nat -C POSTROUTING -o "$tun_name" -j MASQUERADE 2>/dev/null; then
iptables -t nat -A POSTROUTING -o "$tun_name" -j MASQUERADE
persist_iptables_rules
fi
}
apply_iptables_dnat_forwarding() {
local mapping="$1" target="$2" entry listen dest proto
if ! command -v iptables &> /dev/null; then
colorize red "iptables is not available; cannot set up iptables forwarding."
return 1
fi
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
local changed="false"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
for proto in tcp udp; do
if ! iptables -t nat -C PREROUTING -p "$proto" --dport "$listen" -j DNAT --to-destination "${target}:${dest}" 2>/dev/null; then
iptables -t nat -A PREROUTING -p "$proto" --dport "$listen" -j DNAT --to-destination "${target}:${dest}"
changed="true"
fi
if ! iptables -C FORWARD -p "$proto" -d "$target" --dport "$dest" -j ACCEPT 2>/dev/null; then
iptables -I FORWARD -p "$proto" -d "$target" --dport "$dest" -j ACCEPT
changed="true"
fi
done
done
[[ "$changed" == "true" ]] && persist_iptables_rules
}
remove_iptables_dnat_forwarding() {
local mapping="$1" target="$2" entry listen dest proto
command -v iptables &> /dev/null || return 0
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
for proto in tcp udp; do
iptables -t nat -D PREROUTING -p "$proto" --dport "$listen" -j DNAT --to-destination "${target}:${dest}" 2>/dev/null
iptables -D FORWARD -p "$proto" -d "$target" --dport "$dest" -j ACCEPT 2>/dev/null
done
done
persist_iptables_rules
}
ensure_haproxy_installed() {
if ! command -v haproxy &> /dev/null; then
if command -v apt-get &> /dev/null; then
colorize yellow "Installing haproxy..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y haproxy >/dev/null 2>&1
fi
fi
command -v haproxy &> /dev/null
}
apply_haproxy_forwarding() {
local mapping="$1" target="$2" config_name="$3"
ensure_haproxy_installed || { colorize red "haproxy is not available; cannot set up haproxy forwarding."; return 1; }
local cfg="/etc/haproxy/haproxy.cfg"
if [[ ! -f "$cfg" ]]; then
mkdir -p "$(dirname "$cfg")"
cat > "$cfg" <<'EOF'
global
    maxconn 20000
defaults
    mode tcp
    timeout connect 5s
    timeout client 1m
    timeout server 1m
EOF
fi
local marker_start="# BEGIN backhaul:${config_name}"
local marker_end="# END backhaul:${config_name}"
awk -v s="$marker_start" -v e="$marker_end" '
$0==s {skip=1}
!skip {print}
$0==e {skip=0}
' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
local entry listen dest idx=0
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
{
echo "$marker_start"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
if [[ "$listen" == *:* ]]; then
colorize yellow "HAProxy forwarder does not support port ranges (${listen}); skipping this entry."
continue
fi
((idx++))
echo "frontend backhaul_${config_name}_${idx}"
echo "    bind *:${listen}"
echo "    default_backend backhaul_${config_name}_${idx}_be"
echo "backend backhaul_${config_name}_${idx}_be"
echo "    server srv1 ${target}:${dest} check"
done
echo "$marker_end"
} >> "$cfg"
if haproxy -c -f "$cfg" &> /dev/null; then
systemctl enable --now haproxy >/dev/null 2>&1
systemctl reload haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null
colorize green "✔ HAProxy forwarding configured."
else
colorize red "✘ Generated HAProxy config is invalid; not applying. Check with: haproxy -c -f ${cfg}"
return 1
fi
}
remove_haproxy_block() {
local config_name="$1"
local cfg="/etc/haproxy/haproxy.cfg"
[[ -f "$cfg" ]] || return
local marker_start="# BEGIN backhaul:${config_name}"
local marker_end="# END backhaul:${config_name}"
awk -v s="$marker_start" -v e="$marker_end" '
$0==s {skip=1; next}
$0==e {skip=0; next}
!skip {print}
' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
if command -v haproxy &> /dev/null && haproxy -c -f "$cfg" &> /dev/null; then
systemctl reload haproxy 2>/dev/null
fi
}
ensure_ipvsadm_installed() {
if ! command -v ipvsadm &> /dev/null; then
if command -v apt-get &> /dev/null; then
colorize yellow "Installing ipvsadm..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y ipvsadm >/dev/null 2>&1
fi
fi
command -v ipvsadm &> /dev/null
}
apply_ipvs_forwarding() {
local mapping="$1" target="$2" entry listen dest
ensure_ipvsadm_installed || { colorize red "ipvsadm is not available; cannot set up IPVS forwarding."; return 1; }
modprobe ip_vs 2>/dev/null
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
if [[ "$listen" == *:* ]]; then
colorize yellow "IPVS forwarder does not support port ranges (${listen}); skipping this entry."
continue
fi
ipvsadm -D -t "0.0.0.0:${listen}" 2>/dev/null
ipvsadm -A -t "0.0.0.0:${listen}" -s wrr
ipvsadm -a -t "0.0.0.0:${listen}" -r "${target}:${dest}" -m
done
if command -v ipvsadm-save &> /dev/null; then
ipvsadm-save -n > /etc/ipvsadm.rules 2>/dev/null
systemctl enable ipvsadm >/dev/null 2>&1
fi
colorize green "✔ IPVS forwarding configured."
}
remove_ipvs_forwarding() {
local mapping="$1" entry listen dest
command -v ipvsadm &> /dev/null || return
local -a entries=()
IFS=',' read -r -a entries <<< "$mapping"
for entry in "${entries[@]}"; do
entry="${entry// /}"
[[ -z "$entry" ]] && continue
read -r listen dest <<< "$(parse_port_entry "$entry")"
[[ "$listen" == *:* ]] && continue
ipvsadm -D -t "0.0.0.0:${listen}" 2>/dev/null
done
if command -v ipvsadm-save &> /dev/null; then
ipvsadm-save -n > /etc/ipvsadm.rules 2>/dev/null
fi
}
apply_tun_port_forwarding() {
local mapping="$1" forwarder="$2" tun_remote_addr="$3" tun_name="$4" config_name="$5"
[[ -z "$mapping" ]] && return
local target="${tun_remote_addr%/*}"
case "$forwarder" in
iptables)
ensure_tun_masquerade "$tun_name"
apply_iptables_dnat_forwarding "$mapping" "$target"
;;
haproxy)
apply_haproxy_forwarding "$mapping" "$target" "$config_name"
;;
ipvs)
ensure_tun_masquerade "$tun_name"
apply_ipvs_forwarding "$mapping" "$target"
;;
*)
allow_forwarded_ports_firewall "$mapping" "true"
;;
esac
}
remove_tun_port_forwarding() {
local mapping="$1" forwarder="$2" tun_remote_addr="$3" config_name="$4"
local target="${tun_remote_addr%/*}"
case "$forwarder" in
iptables) remove_iptables_dnat_forwarding "$mapping" "$target" ;;
haproxy) remove_haproxy_block "$config_name" ;;
ipvs) remove_ipvs_forwarding "$mapping" ;;
esac
}
ensure_watchdog_installed() {
local unit_service="${service_dir}/backhaul-watchdog.service"
local unit_timer="${service_dir}/backhaul-watchdog.timer"
if [[ -f "$unit_timer" ]] && systemctl is-enabled --quiet backhaul-watchdog.timer 2>/dev/null; then
return
fi
cat > "$unit_service" <<EOF
[Unit]
Description=Backhaul tunnel watchdog

[Service]
Type=oneshot
ExecStart=${PANEL_PATH} --watchdog
EOF
cat > "$unit_timer" <<EOF
[Unit]
Description=Run Backhaul watchdog periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now backhaul-watchdog.timer >/dev/null 2>&1
}
run_watchdog_check() {
local config_path config_name service_name is_tun tun_name
for config_path in "${config_dir}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
logger -t backhaul-watchdog "${service_name} is inactive, restarting" 2>/dev/null
systemctl restart "$service_name" 2>/dev/null
continue
fi
is_tun="false"; tunnel_is_tun "$config_path" && is_tun="true"
if [[ "$is_tun" == "true" ]]; then
tun_name=$(toml_tun_name "$config_path")
if [[ -n "$tun_name" ]] && ! tun_iface_exists "$tun_name"; then
logger -t backhaul-watchdog "${service_name} TUN interface ${tun_name} is down, restarting" 2>/dev/null
systemctl restart "$service_name" 2>/dev/null
fi
fi
done
}
ensure_journal_limits() {
local conf_dir="/etc/systemd/journald.conf.d"
local conf_file="${conf_dir}/backhaul-tunnel.conf"
[[ -f "$conf_file" ]] && return
mkdir -p "$conf_dir" 2>/dev/null
cat > "$conf_file" <<EOF
[Journal]
SystemMaxUse=200M
EOF
systemctl restart systemd-journald >/dev/null 2>&1
}
allow_ipx_protocol_firewall() {
local profile="$1"
local proto=""
case "$profile" in
gre) proto="47" ;;
ipip) proto="4" ;;
icmp) proto="icmp" ;;
*) return 0 ;;
esac
# ufw's `proto` option only recognizes a small keyword whitelist (no raw protocol
# numbers, and no "ipip" keyword at all), so iptables is the actual enforcement here
# regardless of ufw; inserting at the head of INPUT means it takes effect even when
# ufw is separately active, since ACCEPT there is terminal for matching packets.
if command -v iptables &> /dev/null; then
if ! iptables -C INPUT -p "$proto" -j ACCEPT 2>/dev/null; then
iptables -I INPUT -p "$proto" -j ACCEPT
colorize green "Firewall rule added: allow protocol ${proto} (iptables)"
persist_iptables_rules
fi
else
colorize yellow "iptables not found; cannot automatically open protocol ${proto} in the firewall."
fi
if [[ "$profile" == "gre" ]] && command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
ufw allow proto gre from any to any comment "backhaul-ipx-gre" >/dev/null 2>&1
fi
}
tunnel_meta_file() {
echo "${config_dir}/.meta/$1.meta"
}
write_tunnel_meta() {
local config_name="$1" peer_ip="$2" peer_ssh_port="$3"
mkdir -p "${config_dir}/.meta"
{
echo "peer_ip=${peer_ip}"
echo "peer_ssh_port=${peer_ssh_port:-22}"
} > "$(tunnel_meta_file "$config_name")"
}
read_tunnel_meta() {
local config_name="$1" key="$2" meta_file
meta_file=$(tunnel_meta_file "$config_name")
[[ -f "$meta_file" ]] || return 1
grep "^${key}=" "$meta_file" 2>/dev/null | tail -1 | cut -d= -f2-
}
write_tunnel_last_test() {
local config_name="$1" result="$2"
mkdir -p "${config_dir}/.status"
echo "${result}|$(date '+%Y-%m-%d %H:%M:%S')" > "${config_dir}/.status/${config_name}.status"
}
read_tunnel_last_test() {
local config_name="$1"
local f="${config_dir}/.status/${config_name}.status"
[[ -f "$f" ]] && cat "$f" || echo "Never tested|-"
}
toml_get() {
local file="$1" section="$2" key="$3"
awk -v want_section="[$section]" -v want_key="$key" '
FNR==1 { insec=0 }
/^\[/ { insec = ($0 == want_section) }
insec {
n = length(want_key)
if (substr($0,1,n) == want_key && substr($0,n+1,1) ~ /[ =]/) {
line=$0
sub(/^[^=]*=[ \t]*/, "", line)
gsub(/^"|"$/, "", line)
print line
exit
}
}
' "$file" 2>/dev/null
}
tunnel_role() {
local file="$1"
if grep -q '^\[listener\]$' "$file" 2>/dev/null; then
echo "server"; return
fi
if grep -q '^\[dialer\]$' "$file" 2>/dev/null; then
echo "client"; return
fi
toml_get "$file" "ipx" "mode"
}
tunnel_is_tun() { grep -q '^\[tun\]$' "$1" 2>/dev/null; }
tunnel_is_ipx() { grep -q '^\[ipx\]$' "$1" 2>/dev/null; }
tunnel_port_number() {
local file="$1" role="$2" addr
if [[ "$role" == "server" ]]; then
addr=$(toml_get "$file" "listener" "bind_addr")
else
addr=$(toml_get "$file" "dialer" "remote_addr")
fi
if [[ -z "$addr" ]]; then
toml_get "$file" "tun" "health_port"
return
fi
echo "${addr##*:}"
}
tunnel_peer_ip() {
local file="$1" config_name="$2" ip
ip=$(read_tunnel_meta "$config_name" "peer_ip")
[[ -z "$ip" ]] && ip=$(toml_get "$file" "ipx" "dst_ip")
echo "$ip"
}
tunnel_peer_ssh_port() {
local p
p=$(read_tunnel_meta "$1" "peer_ssh_port")
echo "${p:-22}"
}
tcp_port_open() {
local host="$1" port="$2" timeout="${3:-3}"
timeout "$timeout" bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null
}
ping_stats() {
local host="$1" count="${2:-5}"
if ! command -v ping &> /dev/null; then
echo "NA NA"; return 1
fi
local out
out=$(ping -c "$count" -W 2 "$host" 2>/dev/null)
if [[ -z "$out" ]]; then
echo "NA NA"; return 1
fi
local avg loss
avg=$(echo "$out" | grep -oP '(?<= = )[0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+(?= ms)' | awk -F/ '{print $2}')
loss=$(echo "$out" | grep -oP '[0-9]+(?=% packet loss)')
echo "${avg:-NA} ${loss:-NA}"
}
tun_iface_exists() {
ip link show "$1" &>/dev/null
}
check_health_endpoint() {
local port="$1" http_code
[[ -z "$port" ]] && { echo "N/A"; return 1; }
if command -v curl &> /dev/null; then
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null)
if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
echo "OK"
return 0
fi
fi
if tcp_port_open "127.0.0.1" "$port" 2; then
echo "OPEN"
return 0
fi
echo "DOWN"
return 1
}
tunnel_traffic_stats() {
local service_name="$1" rx tx
rx=$(systemctl show "$service_name" -p IPIngressBytes --value 2>/dev/null)
tx=$(systemctl show "$service_name" -p IPEgressBytes --value 2>/dev/null)
if [[ -z "$rx" || "$rx" == "[not set]" || "$rx" == "18446744073709551615" ]]; then
echo ""
return
fi
if command -v numfmt &> /dev/null; then
rx=$(numfmt --to=iec --suffix=B "$rx" 2>/dev/null)
tx=$(numfmt --to=iec --suffix=B "$tx" 2>/dev/null)
fi
echo "RX ${rx:-0}  TX ${tx:-0}"
}
local_role_ready() {
local config_path="$1" is_tun="$2" tun_name="$3" config_name service_name
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
ROLE_READY=0; ROLE_REASON="service ${service_name} is not active"
return
fi
if [[ "$is_tun" == "true" ]] && ! tun_iface_exists "$tun_name"; then
ROLE_READY=0; ROLE_REASON="TUN interface (${tun_name}) is not up yet"
return
fi
ROLE_READY=1; ROLE_REASON="ready"
}
run_tunnel_diagnostics() {
local config_path="$1"
if [[ ! -f "$config_path" ]]; then
colorize red "Config not found."; press_key; return 1
fi
local config_name role is_tun is_ipx tun_name port peer_ip ssh_port my_label peer_label
config_name=$(basename "${config_path%.toml}")
role=$(tunnel_role "$config_path")
is_tun="false"; tunnel_is_tun "$config_path" && is_tun="true"
is_ipx="false"; tunnel_is_ipx "$config_path" && is_ipx="true"
tun_name=$(toml_tun_name "$config_path")
port=$(tunnel_port_number "$config_path" "$role")
peer_ip=$(tunnel_peer_ip "$config_path" "$config_name")
ssh_port=$(tunnel_peer_ssh_port "$config_name")
if [[ "$role" == "server" ]]; then my_label="IRAN"; peer_label="KHAREJ"; else my_label="KHAREJ"; peer_label="IRAN"; fi

clear
colorize cyan "Tunnel Diagnostics: ${config_name}" bold
echo ""
colorize blue "── ${my_label} side (this server) ──" bold
local_role_ready "$config_path" "$is_tun" "$tun_name"
if [[ "$ROLE_READY" == "1" ]]; then
colorize green "✔ ${my_label} side is ready"
else
colorize red "✘ ${my_label} side is not ready — ${ROLE_REASON}"
fi
if [[ "$is_tun" == "true" ]]; then
local health_port health_status
health_port=$(toml_get "$config_path" "tun" "health_port")
if [[ -n "$health_port" ]]; then
health_status=$(check_health_endpoint "$health_port")
case "$health_status" in
OK) colorize green "✔ Health endpoint (:${health_port}): responding" ;;
OPEN) colorize yellow "Health endpoint (:${health_port}): port open but no HTTP response (may not be an HTTP endpoint)" ;;
*) colorize red "✘ Health endpoint (:${health_port}): not responding" ;;
esac
fi
fi
echo ""

local avg="NA" loss="NA"
if [[ -z "$peer_ip" ]]; then
colorize yellow "Peer IP is not set. Set it from the tunnel's Edit menu to enable full diagnostics (SSH/port/latency/loss)."
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
if [[ "$is_ipx" != "true" && -n "$port" ]]; then
if tcp_port_open "$peer_ip" "$port" 3; then
colorize green "✔ Tunnel port (${port}) is open on this side"
else
colorize yellow "Tunnel port (${port}) did not respond (normal if the peer only listens the other way)"
fi
fi
echo ""
fi

if [[ "$ROLE_READY" != "1" ]]; then
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
if [[ "$is_tun" == "true" ]]; then
local tun_remote
tun_remote=$(toml_get "$config_path" "tun" "remote_addr")
tun_remote="${tun_remote%/*}"
if command -v ping &> /dev/null && ping -c 3 -W 2 "$tun_remote" &> /dev/null; then
colorize green "✔ Tunnel is up — ${tun_remote} is reachable through the tunnel"
result="ok"
else
colorize red "✘ Services are up but the tunnel isn't answering yet."
colorize yellow "Check that the peer side is configured with matching settings (tunnel name, subnet)."
fi
else
colorize green "✔ Both sides are reachable and services are active."
colorize yellow "For this transport, the real connection is established once traffic flows; check the service status from Tunnel Management too."
result="ok"
fi
write_tunnel_last_test "$config_name" "$result"
echo ""
press_key
}
install_jq() {
if ! command -v jq &> /dev/null; then
if command -v apt-get &> /dev/null; then
colorize yellow "Installing jq..."
sudo apt-get update && sudo apt-get install -y jq
else
colorize red "Error: Unsupported package manager. Please install jq manually."
press_key
exit 1
fi
fi
}
download_and_extract_backhaul() {
local is_menu="false" backup_bin=""
if [[ "$1" == "menu" ]]; then
is_menu="true"
if [[ -f "${config_dir}/backhaul_premium" ]]; then
backup_bin="${config_dir}/.backhaul_premium.prev"
cp -p "${config_dir}/backhaul_premium" "$backup_bin"
fi
rm -f "${config_dir}/backhaul_premium" >/dev/null 2>&1
colorize cyan "Restart all services after updating to new core" bold
sleep 2
else
[[ -f "${config_dir}/backhaul_premium" ]] && return 1
fi
ARCH=$(uname -m)
case "$ARCH" in
x86_64)
PRIMARY_URL="http://en.backhaul-dev.com:2095/backhaul_premium_amd64.tar.gz"
FALLBACK_URL="http://ir.backhaul-dev.com:2095/backhaul_premium_amd64.tar.gz"
;;
arm64|aarch64)
PRIMARY_URL="http://en.backhaul-dev.com:2095/backhaul_premium_arm64.tar.gz"
FALLBACK_URL="http://ir.backhaul-dev.com:2095/backhaul_premium_arm64.tar.gz"
;;
*)
colorize red "Unsupported architecture: $ARCH."
[[ -n "$backup_bin" ]] && mv -f "$backup_bin" "${config_dir}/backhaul_premium"
[[ "$is_menu" == "true" ]] && return 1
exit 1
;;
esac
DOWNLOAD_DIR=$(mktemp -d)
echo "Downloading Backhaul..."
local download_ok="true"
if ! curl -sSL --max-time 10 -o "$DOWNLOAD_DIR/backhaul.tar.gz" "$PRIMARY_URL"; then
colorize yellow "Primary download failed. Trying fallback..."
if ! curl -sSL --max-time 30 -o "$DOWNLOAD_DIR/backhaul.tar.gz" "$FALLBACK_URL"; then
colorize red "Download failed."
download_ok="false"
fi
fi
if [[ "$download_ok" == "false" ]]; then
rm -rf "$DOWNLOAD_DIR"
if [[ -n "$backup_bin" ]]; then
mv -f "$backup_bin" "${config_dir}/backhaul_premium"
colorize yellow "Restored the previous core."
fi
[[ "$is_menu" == "true" ]] && { press_key; return 1; }
exit 1
fi
mkdir -p "$config_dir"
tar -xzf "$DOWNLOAD_DIR/backhaul.tar.gz" -C "$config_dir"
chmod u+x "${config_dir}/backhaul_premium"
rm -rf "$DOWNLOAD_DIR"
if ! "${config_dir}/backhaul_premium" -v &> /dev/null; then
colorize red "New core failed a basic sanity check (backhaul_premium -v)."
if [[ -n "$backup_bin" ]]; then
mv -f "$backup_bin" "${config_dir}/backhaul_premium"
colorize yellow "Restored the previous core."
else
colorize red "No previous core available to restore!"
fi
[[ "$is_menu" == "true" ]] && { press_key; return 1; }
exit 1
fi
[[ -n "$backup_bin" ]] && rm -f "$backup_bin"
colorize green "Backhaul installation completed."
}
install_jq
download_and_extract_backhaul
declare -A CONFIG
reset_config() {
CONFIG=()
}
prompt_connection_section() {
local mode="$1"  # server or client
colorize blue "━━━ Connection Configuration ━━━" bold
if [[ "$mode" == "server" ]]; then
prompt_with_default "Bind Address" ":8443" CONFIG[bind_addr]
if [[ -n "${CONFIG[bind_addr]}" && "${CONFIG[bind_addr]}" != *:* ]]; then
CONFIG[bind_addr]=":${CONFIG[bind_addr]}"
fi
else
while true; do
echo -ne "[*] IRAN Server Address [IP:Port] or [Domain:Port]: "
read -r CONFIG[remote_addr]
if [[ -z "${CONFIG[remote_addr]}" ]]; then
colorize red "Server address cannot be empty."
continue
fi
if [[ "${CONFIG[remote_addr]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ || \
"${CONFIG[remote_addr]}" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]; then
break
else
colorize red "Invalid format. Use IP:Port or Domain:Port."
fi
done
if [[ "${CONFIG[transport_type]}" == "ws" || "${CONFIG[transport_type]}" == "wss" || "${CONFIG[transport_type]}" == "wsmux" || "${CONFIG[transport_type]}" == "wssmux" || "${CONFIG[transport_type]}" == "xwsmux" ]]; then
echo -ne "[-] Edge IP/Domain (optional, press Enter to skip): "
read -r CONFIG[edge_ip]
fi
CONFIG[dial_timeout]="10"
CONFIG[retry_interval]="3"
fi
local default_peer_ip=""
if [[ "$mode" == "client" ]]; then
default_peer_ip="${CONFIG[remote_addr]%%:*}"
[[ "$default_peer_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || default_peer_ip=""
fi
prompt_with_default "Peer Server IP (other side, optional, enables cross-server diagnostics)" "$default_peer_ip" CONFIG[peer_ip]
if [[ -n "${CONFIG[peer_ip]}" ]]; then
prompt_with_default "Peer SSH Port (for diagnostics)" "22" CONFIG[peer_ssh_port]
fi
echo ""
}
VALID_ALGORITHMS=("aes-256-gcm" "chacha20-poly1305" "aes-128-gcm")
is_valid_algorithm() {
local input="$1"
for alg in "${VALID_ALGORITHMS[@]}"; do
if [[ "$input" == "$alg" ]]; then
return 0
fi
done
return 1
}
prompt_security_section() {
local is_ipx="$1"
colorize blue "━━━ Security Configuration ━━━" bold
if [[ "$is_ipx" == "true" ]]; then
prompt_boolean "Enable Encryption" "true" CONFIG[enable_encryption]
if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
echo
while true; do
colorize magenta "Available algorithms: aes-256-gcm, chacha20-poly1305, aes-128-gcm"
prompt_with_default "Algorithm" "aes-256-gcm" CONFIG[algorithm]
if is_valid_algorithm "${CONFIG[algorithm]}"; then
break
else
colorize red "Invalid algorithm selected. Please choose one from the list."
echo
fi
done
prompt_with_default "PSK (32-char base64)" "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=" CONFIG[psk]
prompt_with_default "KDF Iterations" "100000" CONFIG[kdf_iterations]
fi
else
prompt_with_default "Security Token" "your_token" CONFIG[token]
CONFIG[enable_encryption]="false"
fi
echo ""
}
prompt_transport_section() {
local mode="$1"
local is_ipx="false"
colorize blue "━━━ Transport Configuration ━━━" bold
local valid_transports=(tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls tun)
echo "Available transports:"
printf '  • %s\n' "${valid_transports[@]}"
while true; do
echo -ne "Select transport: "
read -r CONFIG[transport_type]
[[ " ${valid_transports[*]} " =~ " ${CONFIG[transport_type]} " ]] && break
colorize red "Invalid transport."
done
if [[ "${CONFIG[transport_type]}" == "tun" ]]; then
echo
local encapsulations=(tcp ipx)
echo "Available encapsulations:"
printf '  • %s\n' "${encapsulations[@]}"
while true; do
echo -ne "Select encapsulation: "
read -r CONFIG[tun_encapsulation]
[[ " ${encapsulations[*]} " =~ " ${CONFIG[tun_encapsulation]} " ]] && break
colorize red "Invalid encapsulation."
done
fi
echo
if [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]]; then
is_ipx="true"
fi
if [[ "$is_ipx" != "true" ]]; then
prompt_boolean "Enable TCP_NODELAY" "true" CONFIG[nodelay]
fi
if [[ "$mode" == "server" ]]; then
if [[ "${CONFIG[transport_type]}" == "tcp" ]]; then
prompt_boolean "Accept UDP over TCP" "false" CONFIG[accept_udp]
fi
if [[ ! "${CONFIG[transport_type]}" =~ ^(tun|ws)$ ]] && [[ "$is_ipx" != "true" ]]; then
prompt_boolean "Enable Proxy Protocol" "false" CONFIG[proxy_protocol]
fi
else
if [[ "${CONFIG[transport_type]}" != "tun" ]]; then
prompt_with_default "Connection Pool" "8" CONFIG[connection_pool]
fi
fi
CONFIG[heartbeat_interval]="10"
CONFIG[heartbeat_timeout]="25"
if [[ "$is_ipx" != "true" ]]; then
CONFIG[keepalive_period]="40"
fi
echo ""
}
prompt_mux_section() {
local transport="$1"
if [[ ! "$transport" =~ mux$ ]]; then
return
fi
colorize blue "━━━ Mux Configuration ━━━" bold
prompt_with_default "Mux Version [1 or 2]" "2" CONFIG[mux_version]
prompt_with_default "Mux Concurrency" "8" CONFIG[mux_concurrency]
CONFIG[mux_framesize]="32768"
CONFIG[mux_recievebuffer]="4194304"
CONFIG[mux_streambuffer]="2097152"
echo ""
}
prompt_tun_section() {
local transport="$1"
local mode="$2"
local is_ipx="$3"
[[ "$transport" != "tun" ]] && return
colorize blue "━━━ TUN Configuration ━━━" bold
local suggested_name
suggested_name=$(suggest_tun_name)
while true; do
prompt_with_default "TUN Device Name" "$suggested_name" CONFIG[tun_name]
if ! is_valid_tun_name "${CONFIG[tun_name]}"; then
colorize red "Invalid name. Use up to 15 letters/digits/-/_ characters (Linux interface name limit)."
elif is_tun_name_in_use "${CONFIG[tun_name]}"; then
colorize red "Device name '${CONFIG[tun_name]}' is already used by another tunnel on this server. Choose another."
else
break
fi
done
local suggested_third
suggested_third=$(suggest_tun_subnet_third_octet)
local default_local default_remote
if [[ "$mode" == "server" ]]; then
default_local="10.10.${suggested_third}.1/24"
default_remote="10.10.${suggested_third}.2/24"
else
default_local="10.10.${suggested_third}.2/24"
default_remote="10.10.${suggested_third}.1/24"
fi
while true; do
prompt_with_default "TUN Local Address (CIDR)" "$default_local" CONFIG[tun_local_addr]
if ! validate_cidr "${CONFIG[tun_local_addr]}"; then
colorize red "Invalid CIDR format."
continue
fi
if is_tun_subnet_in_use "${CONFIG[tun_local_addr]}"; then
colorize red "This subnet overlaps with an existing tunnel's TUN subnet. Choose a different one."
continue
fi
break
done
while true; do
prompt_with_default "TUN Remote Address (CIDR)" "$default_remote" CONFIG[tun_remote_addr]
if ! validate_cidr "${CONFIG[tun_remote_addr]}"; then
colorize red "Invalid CIDR format."
continue
fi
if is_tun_subnet_in_use "${CONFIG[tun_remote_addr]}"; then
colorize red "This subnet overlaps with an existing tunnel's TUN subnet. Choose a different one."
continue
fi
break
done
if [[ "$is_ipx" == "true" ]]; then
local suggested_port
suggested_port=$(suggest_free_tunnel_port "$mode")
while true; do
prompt_with_default "Health Port" "$suggested_port" CONFIG[tun_health_port]
if is_tunnel_port_in_use "$mode" "${CONFIG[tun_health_port]}"; then
colorize red "Port ${CONFIG[tun_health_port]} is already used by another ${mode} tunnel on this server. Choose another."
else
break
fi
done
else
prompt_with_default "Health Port" "1234" CONFIG[tun_health_port]
fi
if [[ "$is_ipx" == "true" ]]; then
prompt_with_default "MTU" "1320" CONFIG[tun_mtu]
else
prompt_with_default "MTU" "1500" CONFIG[tun_mtu]
fi
echo ""
}
prompt_tls_section() {
local mode="$1"
local transport="$2"
if [[ ! "$transport" =~ ^(anytls|wss|wssmux)$ ]]; then
return
fi
colorize blue "━━━ TLS Configuration ━━━" bold
if [[ "$transport" == "anytls" ]]; then
prompt_with_default "SNI" "www.digikala.com" CONFIG[tls_sni]
fi
if [[ "$mode" == "client" ]]; then
echo
return
fi
if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
colorize red "[*] TLS certificate or key missing, generating self-signed Ed25519 cert..."
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 -days 365 -sha256 -keyout "$KEY_FILE" -out  "$CERT_FILE" -subj "/CN=backhaul.com"
colorize green "[*] Generated $CERT_FILE and $KEY_FILE"
echo
fi
prompt_with_default "TLS Certificate Path" "$CERT_FILE" CONFIG[tls_cert]
prompt_with_default "TLS Key Path" "$KEY_FILE" CONFIG[tls_key]
echo ""
}
prompt_tuning_section() {
local is_ipx="$1"
local is_tun="$2"
colorize blue "━━━ Tuning Configuration ━━━" bold
prompt_boolean "Enable Auto Tuning" "true" CONFIG[auto_tuning]
echo
colorize magenta "Profiles: balanced, fast, latency, resource" normal
prompt_with_default "Kernel Tuning Profile" "balanced" CONFIG[tuning_profile]
prompt_with_default "Workers (0 = auto)" "0" CONFIG[workers]
if [[ "$is_tun" != "true" ]]; then
prompt_with_default "Channel Size" "4096" CONFIG[channel_size]
fi
if [[ "$is_tun" == "true" ]]; then
CONFIG[channel_size]="10_000"
fi
if [[ "$is_ipx" == "true" ]]; then
prompt_with_default "Batch Size" "2048" CONFIG[batch_size]
prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
else
prompt_with_default "TCP MSS (0 = auto)" "0" CONFIG[tcp_mss]
prompt_with_default "SO_RCVBUF (0 = auto)" "0" CONFIG[so_rcvbuf]
prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
fi
if [[ "$is_tun" != "true" ]] && [[ "$is_ipx" != "true" ]]; then
echo
colorize magenta "Buffer Profiles: extreme_low_cpu, ultra_low_cpu, low_cpu, balanced, low_memory" normal
prompt_with_default "Buffer Profile" "balanced" CONFIG[buffer_profile]
prompt_with_default "Read Timeout" "120" CONFIG[read_timeout]
fi
echo ""
}
prompt_logging_section() {
colorize blue "━━━ Logging Configuration ━━━" bold
colorize magenta "Levels: panic, fatal, error, warn, info, debug, trace"
prompt_with_default "Log Level" "info" CONFIG[log_level]
echo ""
}
prompt_accept_udp_section() {
local accept_udp="$1"
[[ "$accept_udp" != "true" ]] && return
CONFIG[ring_size]="64"
CONFIG[frame_size]="2048"
CONFIG[peer_idle_timeout_s]="120"
CONFIG[write_timeout_ms]="3"
}
prompt_ports_section() {
local mode="$1"
local is_tun="$2"
[[ "$mode" != "server" ]] && return
if [[ "$is_tun" != "true" ]]; then
colorize blue "━━━ Port Mapping Configuration ━━━" bold
colorize green "Supported formats:"
echo "  1. 443           - Listen on 443, forward to 443"
echo "  2. 443=5000      - Listen on 443, forward to 5000"
echo "  3. 443-600       - Listen on range 443-600"
echo "  4. 443-600:5201  - Range forwarding to 5201"
echo ""
echo -ne "Enter port mappings (comma-separated): "
read -r CONFIG[ports_mapping]
echo ""
else
colorize blue "━━━ Port Mapping Configuration (tun helper) ━━━" bold
colorize magenta "Forwarder engines:"
echo "  backhaul  - internal TCP-only proxy, no extra setup"
echo "  iptables  - kernel DNAT, TCP + UDP, lowest overhead"
echo "  haproxy   - userspace TCP proxy with backend health-check"
echo "  ipvs      - kernel-level load balancer (ipvsadm), TCP + UDP"
local -a valid_forwarders=(backhaul iptables haproxy ipvs)
while true; do
prompt_with_default "Forwarder" "backhaul" CONFIG[forwarder]
CONFIG[forwarder]="${CONFIG[forwarder],,}"
[[ " ${valid_forwarders[*]} " == *" ${CONFIG[forwarder]} "* ]] && break
colorize red "Invalid forwarder. Choose one of: ${valid_forwarders[*]}"
done
echo ""
colorize green "Supported formats:"
echo "  1. 443           - Listen on 443, forward to 443"
echo "  2. 443=5000      - Listen on 443, forward to 5000"
echo ""
echo -ne "Enter port mappings (comma-separated): "
read -r CONFIG[ports_mapping]
echo ""
fi
}
prompt_ipx_section() {
local is_ipx="$1"
local mode="$2"
[[ "$is_ipx" != "true" ]] && return
colorize blue "━━━ IPX Configuration ━━━" bold
CONFIG[ipx_mode]="$mode"
AVAILABLE_PROFILES=("icmp" "ipip" "udp" "tcp" "gre" "bip")
colorize magenta "Available profiles: ${AVAILABLE_PROFILES[*]}"
while true; do
prompt_with_default "Profile" "tcp" CONFIG[ipx_profile]
CONFIG[ipx_profile]="${CONFIG[ipx_profile],,}"
for profile in "${AVAILABLE_PROFILES[@]}"; do
if [[ "${CONFIG[ipx_profile]}" == "$profile" ]]; then
break 2
fi
done
colorize red "Invalid profile: ${CONFIG[ipx_profile]}"
echo
colorize yellow "Please choose one of: ${AVAILABLE_PROFILES[*]}"
done
prompt_with_default "Listen IP" $SERVER_IP CONFIG[ipx_listen_ip]
while :; do
prompt_with_default "Destination IP" "" CONFIG[ipx_dst_ip]
if [[ -n "${CONFIG[ipx_dst_ip]}" ]]; then
break
fi
colorize red "Destination IP cannot be empty."
done
interface=$(detect_default_interface)
prompt_with_default "Network Interface" "$interface" CONFIG[ipx_interface]
if [[ "${CONFIG[ipx_profile]}" == "icmp" ]]; then
prompt_with_default "ICMP Type" "0" CONFIG[ipx_icmp_type]
prompt_with_default "ICMP Code" "0" CONFIG[ipx_icmp_code]
fi
echo ""
}
generate_toml_config() {
local mode="$1"
local output_file="$2"
local is_tun="$3"
local is_ipx="$4"
{
if [[ "$mode" == "server" ]] && [[ "$is_ipx" == "false" ]]; then
echo "[listener]"
echo "bind_addr = \"${CONFIG[bind_addr]}\""
echo ""
elif [[ "$is_ipx" == "false" ]]; then
echo "[dialer]"
echo "remote_addr = \"${CONFIG[remote_addr]}\""
[[ -n "${CONFIG[edge_ip]}" ]] && echo "edge_ip = \"${CONFIG[edge_ip]}\""
echo "dial_timeout = ${CONFIG[dial_timeout]}"
echo "retry_interval = ${CONFIG[retry_interval]}"
echo ""
fi
echo "[transport]"
echo "type = \"${CONFIG[transport_type]}\""
[[ -n "${CONFIG[nodelay]}" ]] && echo "nodelay = ${CONFIG[nodelay]}"
[[ -n "${CONFIG[keepalive_period]}" ]] && echo "keepalive_period = ${CONFIG[keepalive_period]}"
if [[ "$mode" == "server" ]]; then
[[ -n "${CONFIG[accept_udp]}" ]] && echo "accept_udp = ${CONFIG[accept_udp]}"
[[ -n "${CONFIG[proxy_protocol]}" ]] && echo "proxy_protocol = ${CONFIG[proxy_protocol]}"
else
[[ -n "${CONFIG[connection_pool]}" ]] && [[ "${CONFIG[connection_pool]}" != "0" ]] && \
echo "connection_pool = ${CONFIG[connection_pool]}"
fi
[[ -n "${CONFIG[heartbeat_interval]}" ]] && echo "heartbeat_interval = ${CONFIG[heartbeat_interval]}"
[[ -n "${CONFIG[heartbeat_timeout]}" ]] && echo "heartbeat_timeout = ${CONFIG[heartbeat_timeout]}"
echo ""
if [[ "$is_tun" == "true" ]]; then
echo "[tun]"
echo "encapsulation = \"${CONFIG[tun_encapsulation]}\""
echo "name = \"${CONFIG[tun_name]}\""
echo "local_addr = \"${CONFIG[tun_local_addr]}\""
echo "remote_addr = \"${CONFIG[tun_remote_addr]}\""
echo "health_port = ${CONFIG[tun_health_port]}"
echo "mtu = ${CONFIG[tun_mtu]}"
echo ""
fi
if [[ "$is_ipx" == "true" ]]; then
echo "[ipx]"
echo "mode = \"${CONFIG[ipx_mode]}\""
echo "profile = \"${CONFIG[ipx_profile]}\""
echo "listen_ip = \"${CONFIG[ipx_listen_ip]}\""
echo "dst_ip = \"${CONFIG[ipx_dst_ip]}\""
echo "interface = \"${CONFIG[ipx_interface]}\""
[[ -n "${CONFIG[ipx_icmp_type]}" ]] && echo "icmp_type = ${CONFIG[ipx_icmp_type]}"
[[ -n "${CONFIG[ipx_icmp_code]}" ]] && echo "icmp_code = ${CONFIG[ipx_icmp_code]}"
echo ""
fi
if [[ "${CONFIG[transport_type]}" =~ mux$ ]]; then
echo "[mux]"
echo "mux_version = ${CONFIG[mux_version]}"
echo "mux_framesize = ${CONFIG[mux_framesize]}"
echo "mux_recievebuffer = ${CONFIG[mux_recievebuffer]}"
echo "mux_streambuffer = ${CONFIG[mux_streambuffer]}"
[[ -n "${CONFIG[mux_concurrency]}" ]] && echo "mux_concurrency = ${CONFIG[mux_concurrency]}"
echo ""
fi
echo "[security]"
if [[ "$is_ipx" == "true" ]]; then
echo "enable_encryption = ${CONFIG[enable_encryption]}"
[[ "${CONFIG[enable_encryption]}" == "true" ]] && {
echo "algorithm = \"${CONFIG[algorithm]}\""
echo "psk = \"${CONFIG[psk]}\""
echo "kdf_iterations = ${CONFIG[kdf_iterations]}"
}
else
echo "token = \"${CONFIG[token]}\""
fi
echo ""
if [[ -n "${CONFIG[tls_sni]}" || -n "${CONFIG[tls_cert]}" ]]; then
echo "[tls]"
[[ -n "${CONFIG[tls_sni]}" ]]  && echo "sni = \"${CONFIG[tls_sni]}\""
[[ -n "${CONFIG[tls_cert]}" ]] && echo "tls_cert = \"${CONFIG[tls_cert]}\""
[[ -n "${CONFIG[tls_key]}" ]]  && echo "tls_key = \"${CONFIG[tls_key]}\""
echo ""
fi
echo "[tuning]"
[[ -n "${CONFIG[auto_tuning]}" ]]     && echo "auto_tuning = ${CONFIG[auto_tuning]}"
[[ -n "${CONFIG[tuning_profile]}" ]]  && echo "tuning_profile = \"${CONFIG[tuning_profile]}\""
[[ -n "${CONFIG[workers]}" ]]         && echo "workers = ${CONFIG[workers]}"
[[ -n "${CONFIG[channel_size]}" ]]    && echo "channel_size = ${CONFIG[channel_size]}"
[[ -n "${CONFIG[tcp_mss]}" ]]         && echo "tcp_mss = ${CONFIG[tcp_mss]}"
[[ -n "${CONFIG[so_rcvbuf]}" ]]       && echo "so_rcvbuf = ${CONFIG[so_rcvbuf]}"
[[ -n "${CONFIG[so_sndbuf]}" ]]       && echo "so_sndbuf = ${CONFIG[so_sndbuf]}"
[[ -n "${CONFIG[buffer_profile]}" ]]  && echo "buffer_profile = \"${CONFIG[buffer_profile]}\""
[[ -n "${CONFIG[batch_size]}" ]]      && echo "batch_size = ${CONFIG[batch_size]}"
[[ -n "${CONFIG[read_timeout]}" ]]    && echo "read_timeout = ${CONFIG[read_timeout]}"
echo ""
if [[ "${CONFIG[accept_udp]}" == "true" ]]; then
echo "[accept_udp]"
echo "ring_size = ${CONFIG[ring_size]}"
echo "frame_size = ${CONFIG[frame_size]}"
echo "peer_idle_timeout_s = ${CONFIG[peer_idle_timeout_s]}"
echo "write_timeout_ms = ${CONFIG[write_timeout_ms]}"
echo ""
fi
echo "[logging]"
echo "log_level = \"${CONFIG[log_level]}\""
echo ""
if [[ "$mode" == "server" ]] ; then
echo "[ports]"
[[ -n "${CONFIG[forwarder]}" ]]  && echo "forwarder = \"${CONFIG[forwarder]}\""
echo "mapping = ["
IFS=',' read -r -a ports <<< "${CONFIG[ports_mapping]}"
for port in "${ports[@]}"; do
[[ -n "$port" ]] && echo "    \"${port// /}\","
done
echo "]"
fi
} > "$output_file"
}
configure_server() {
local mode="$1"  # server or client
local mode_name
if [[ "$mode" == "server" ]]; then
mode_name="IRAN (Server)"
else
mode_name="KHAREJ (Client)"
fi
clear
colorize cyan "Configuring $mode_name" bold
echo ""
reset_config
prompt_transport_section "$mode"
local is_tun="false"
local is_ipx="false"
[[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun="true"
[[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"
prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx"
prompt_ipx_section "$is_ipx" "$mode"
if [[ "$is_ipx" != "true" ]]; then
prompt_connection_section "$mode"
fi
prompt_security_section "$is_ipx"
prompt_accept_udp_section "${CONFIG[accept_udp]}"
prompt_mux_section "${CONFIG[transport_type]}"
prompt_tls_section "$mode" "${CONFIG[transport_type]}"
prompt_tuning_section "$is_ipx" "$is_tun"
prompt_logging_section
prompt_ports_section "$mode" "$is_tun"
local tunnel_port
if [[ "$mode" == "server" ]]; then
tunnel_port=$(echo "${CONFIG[bind_addr]}" | grep -oP ':\K[0-9]+$')
else
tunnel_port=$(echo "${CONFIG[remote_addr]}" | grep -oP ':\K[0-9]+$')
fi
if [[ -z "$tunnel_port" ]]; then
tunnel_port=$(echo "${CONFIG[tun_health_port]}")
fi
local config_file
if [[ "$mode" == "server" ]]; then
config_file="${config_dir}/iran${tunnel_port}.toml"
else
config_file="${config_dir}/kharej${tunnel_port}.toml"
fi
generate_toml_config "$mode" "$config_file" "$is_tun" "$is_ipx"
local service_type
[[ "$mode" == "server" ]] && service_type="iran" || service_type="kharej"
if [[ "$is_tun" == "true" ]]; then
prepare_tun_ipx_kernel "$is_ipx" "${CONFIG[ipx_profile]}" "${CONFIG[tun_name]}"
fi
if [[ "$is_ipx" == "true" ]]; then
allow_ipx_protocol_firewall "${CONFIG[ipx_profile]}"
fi
local config_name
config_name=$(basename "${config_file%.toml}")
if [[ "$mode" == "server" ]]; then
if [[ "$is_tun" == "true" ]]; then
apply_tun_port_forwarding "${CONFIG[ports_mapping]}" "${CONFIG[forwarder]}" "${CONFIG[tun_remote_addr]}" "${CONFIG[tun_name]}" "$config_name"
else
allow_forwarded_ports_firewall "${CONFIG[ports_mapping]}" "${CONFIG[accept_udp]}"
fi
fi
create_systemd_service "$service_type" "$tunnel_port" "$config_file"
local peer_ip_for_meta="${CONFIG[peer_ip]}"
[[ -z "$peer_ip_for_meta" && "$is_ipx" == "true" ]] && peer_ip_for_meta="${CONFIG[ipx_dst_ip]}"
write_tunnel_meta "$config_name" "$peer_ip_for_meta" "${CONFIG[peer_ssh_port]}"
ensure_watchdog_installed
ensure_journal_limits
echo ""
colorize green "✔ Configuration completed successfully!" bold
echo ""
run_tunnel_diagnostics "$config_file"
}
create_systemd_service() {
local type="$1"
local port="$2"
local config_file="$3"
local service_file="${service_dir}/backhaul-${type}${port}.service"
local desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"
cat > "$service_file" <<EOF
[Unit]
Description=Backhaul $desc_type Port $port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${config_dir}/backhaul_premium -c $config_file
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
systemctl enable --now "backhaul-${type}${port}.service" >/dev/null 2>&1
colorize green "✔ Service backhaul-${type}${port} created and started" bold
}
SERVER_IP=$(hostname -I | awk '{print $1}')
SERVER_COUNTRY=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.country')
SERVER_ISP=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.isp')
display_logo() {
echo -e "\033[36m"
cat << "EOF"
▗▄▄▖  ▗▄▖  ▗▄▄▖▗▖ ▗▖▗▖ ▗▖ ▗▄▖ ▗▖ ▗▖▗▖
▐▌ ▐▌▐▌ ▐▌▐▌   ▐▌▗▞▘▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▐▌
▐▛▀▚▖▐▛▀▜▌▐▌   ▐▛▚▖ ▐▛▀▜▌▐▛▀▜▌▐▌ ▐▌▐▌
▐▙▄▞▘▐▌ ▐▌▝▚▄▄▖▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▝▚▄▞▘▐▙▄▄▖
Lightning-fast reverse tunneling solution
EOF
echo -e "\033[0m\033[32m"
echo -e "Script Version: \033[33m${SCRIPT_VERSION}\033[32m"
[[ -f "${config_dir}/backhaul_premium" ]] && \
echo -e "Core Version: \033[33m$($config_dir/backhaul_premium -v)\033[32m"
}
display_server_info() {
echo -e "\e[93m═══════════════════════════════════════════\e[0m"
echo -e "\033[36mIP Address:\033[0m $SERVER_IP"
echo -e "\033[36mLocation:\033[0m $SERVER_COUNTRY"
echo -e "\033[36mDatacenter:\033[0m $SERVER_ISP"
}
display_backhaul_core_status() {
if [[ -f "${config_dir}/backhaul_premium" ]]; then
echo -e "\033[36mBackhaul Core:\033[0m \033[32mInstalled\033[0m"
else
echo -e "\033[36mBackhaul Core:\033[0m \033[31mNot installed\033[0m"
fi
echo -e "\e[93m═══════════════════════════════════════════\e[0m"
}
check_config_backup() {
missing_services=()
for config in "${config_dir}"/iran*.toml "${config_dir}"/kharej*.toml; do
[ -e "$config" ] || continue
fname=$(basename "$config")
if [[ "$fname" =~ ^(iran|kharej)([0-9]+)\.toml$ ]]; then
location="${BASH_REMATCH[1]}"
tunnel_port="${BASH_REMATCH[2]}"
service_file="${service_dir}/backhaul-${location}${tunnel_port}.service"
if [[ ! -f "$service_file" ]]; then
missing_services+=("$service_file:$location:$tunnel_port")
fi
fi
done
[[ ${#missing_services[@]} -eq 0 ]] && return 0
echo
colorize red "Missing service files:" bold
for entry in "${missing_services[@]}"; do
service_file="${entry%%:*}"
location="${entry#*:}"; location="${location%%:*}"
tunnel_port="${entry##*:}"
echo "- $service_file (type: $location, port: $tunnel_port)"
done
echo
read -r -p "Do you want to create missing service files? (y/n): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
for entry in "${missing_services[@]}"; do
service_file="${entry%%:*}"
location="${entry#*:}"; location="${location%%:*}"
tunnel_port="${entry##*:}"
config_file="${config_dir}/${location}${tunnel_port}.toml"
desc_loc="$(tr '[:lower:]' '[:upper:]' <<< "${location:0:1}")${location:1}"
cat > "$service_file" <<EOF
[Unit]
Description=Backhaul $desc_loc Port $tunnel_port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${config_dir}/backhaul_premium -c $config_file
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
sudo systemctl daemon-reload
sudo systemctl enable --now "$(basename "$service_file")"
echo "Created and started $(basename "$service_file")"
done
fi
sleep 2
}
check_config_backup
check_tunnel_status() {
if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
colorize red "No config files found." bold
press_key
return 1
fi
clear
colorize yellow "Checking all services status..." bold
sleep 1
echo
for config_path in "$config_dir"/{iran,kharej}*.toml; do
[ -f "$config_path" ] || continue
config_name=$(basename "$config_path")
config_name="${config_name%.toml}"
service_name="backhaul-${config_name}.service"
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
tunnel_management() {
if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
colorize red "No config files found." bold
press_key
return 1
fi
clear
colorize cyan "Existing services:" bold
echo
local index=1
declare -a configs
for config_path in "$config_dir"/{iran,kharej}*.toml; do
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
colorize yellow "R) Restart all tunnels"
echo
echo -ne "Enter your choice (0 to return): "
read -r choice
[[ "$choice" == "0" ]] && return
if [[ "$choice" =~ ^[Rr]$ ]]; then
restart_all_tunnels
return
fi
while ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#configs[@]} )); do
colorize red "Invalid choice."
echo -ne "Enter your choice (0 to return): "
read -r choice
[[ "$choice" == "0" ]] && return
[[ "$choice" =~ ^[Rr]$ ]] && { restart_all_tunnels; return; }
done
selected_config="${configs[$((choice - 1))]}"
tunnel_detail_page "$selected_config"
}
restart_all_tunnels() {
local config_path config_name service_name
clear
colorize yellow "Restarting all tunnels..." bold
echo ""
for config_path in "${config_dir}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
systemctl restart "$service_name" 2>/dev/null
sleep 1
if systemctl is-active --quiet "$service_name"; then
colorize green "✔ ${service_name} restarted"
else
colorize red "✘ ${service_name} failed to restart"
fi
done
echo ""
press_key
}
load_toml_ports_mapping() {
awk '
/^mapping = \[/ { inarr=1; next }
inarr && /^\]/ { inarr=0 }
inarr {
line=$0
gsub(/^[ \t]+|[ \t]*,?[ \t]*$/, "", line)
gsub(/^"|"$/, "", line)
if (length(line) > 0) printf "%s,", line
}
' "$1" 2>/dev/null | sed 's/,$//'
}
load_toml_into_config() {
local file="$1"
reset_config
CONFIG[bind_addr]=$(toml_get "$file" "listener" "bind_addr")
CONFIG[remote_addr]=$(toml_get "$file" "dialer" "remote_addr")
CONFIG[edge_ip]=$(toml_get "$file" "dialer" "edge_ip")
CONFIG[transport_type]=$(toml_get "$file" "transport" "type")
CONFIG[accept_udp]=$(toml_get "$file" "transport" "accept_udp")
CONFIG[proxy_protocol]=$(toml_get "$file" "transport" "proxy_protocol")
CONFIG[connection_pool]=$(toml_get "$file" "transport" "connection_pool")
CONFIG[tun_encapsulation]=$(toml_get "$file" "tun" "encapsulation")
CONFIG[tun_name]=$(toml_get "$file" "tun" "name")
CONFIG[tun_local_addr]=$(toml_get "$file" "tun" "local_addr")
CONFIG[tun_remote_addr]=$(toml_get "$file" "tun" "remote_addr")
CONFIG[tun_health_port]=$(toml_get "$file" "tun" "health_port")
CONFIG[ipx_mode]=$(toml_get "$file" "ipx" "mode")
CONFIG[ipx_profile]=$(toml_get "$file" "ipx" "profile")
CONFIG[ipx_listen_ip]=$(toml_get "$file" "ipx" "listen_ip")
CONFIG[ipx_dst_ip]=$(toml_get "$file" "ipx" "dst_ip")
CONFIG[ipx_interface]=$(toml_get "$file" "ipx" "interface")
CONFIG[ipx_icmp_type]=$(toml_get "$file" "ipx" "icmp_type")
CONFIG[ipx_icmp_code]=$(toml_get "$file" "ipx" "icmp_code")
CONFIG[mux_version]=$(toml_get "$file" "mux" "mux_version")
CONFIG[mux_concurrency]=$(toml_get "$file" "mux" "mux_concurrency")
CONFIG[enable_encryption]=$(toml_get "$file" "security" "enable_encryption")
CONFIG[algorithm]=$(toml_get "$file" "security" "algorithm")
CONFIG[psk]=$(toml_get "$file" "security" "psk")
CONFIG[kdf_iterations]=$(toml_get "$file" "security" "kdf_iterations")
CONFIG[token]=$(toml_get "$file" "security" "token")
CONFIG[tls_sni]=$(toml_get "$file" "tls" "sni")
CONFIG[tls_cert]=$(toml_get "$file" "tls" "tls_cert")
CONFIG[tls_key]=$(toml_get "$file" "tls" "tls_key")
CONFIG[auto_tuning]=$(toml_get "$file" "tuning" "auto_tuning")
CONFIG[tuning_profile]=$(toml_get "$file" "tuning" "tuning_profile")
CONFIG[workers]=$(toml_get "$file" "tuning" "workers")
CONFIG[log_level]=$(toml_get "$file" "logging" "log_level")
CONFIG[forwarder]=$(toml_get "$file" "ports" "forwarder")
CONFIG[ports_mapping]=$(load_toml_ports_mapping "$file")
local config_name
config_name=$(basename "${file%.toml}")
CONFIG[peer_ip]=$(tunnel_peer_ip "$file" "$config_name")
CONFIG[peer_ssh_port]=$(tunnel_peer_ssh_port "$config_name")
}
backup_tunnel() {
local config_path="$1" service_path="$2" config_name="$3" ts backup_dir
ts=$(date +%Y%m%d%H%M%S)
backup_dir="${config_dir}/.backups/${config_name}.${ts}"
mkdir -p "$backup_dir"
[[ -f "$config_path" ]] && cp -p "$config_path" "$backup_dir/config.toml"
[[ -f "$service_path" ]] && cp -p "$service_path" "$backup_dir/service.service"
echo "$backup_dir"
}
restore_tunnel_backup() {
local backup_dir="$1" config_path="$2" service_path="$3" service_name="$4"
[[ -f "$backup_dir/config.toml" ]] && cp -p "$backup_dir/config.toml" "$config_path"
[[ -f "$backup_dir/service.service" ]] && cp -p "$backup_dir/service.service" "$service_path"
systemctl daemon-reload
systemctl restart "$service_name" 2>/dev/null
}
toggle_tunnel_enabled() {
local service_name="$1"
if systemctl is-active --quiet "$service_name"; then
systemctl disable --now "$service_name" >/dev/null 2>&1
colorize yellow "Tunnel disabled."
else
systemctl enable --now "$service_name" >/dev/null 2>&1
sleep 1
if systemctl is-active --quiet "$service_name"; then
colorize green "Tunnel enabled."
else
colorize red "Failed to enable. Check logs: journalctl -eu ${service_name}"
fi
fi
press_key
}
apply_ports_mapping() {
local config_path="$1" service_name="$2" new_mapping="$3" service_path config_name backup_dir
service_path="${service_dir}/${service_name}"
config_name=$(basename "${config_path%.toml}")
backup_dir=$(backup_tunnel "$config_path" "$service_path" "$config_name")

local is_tun="false" forwarder old_mapping tun_remote_addr tun_name
tunnel_is_tun "$config_path" && is_tun="true"
forwarder=$(toml_get "$config_path" "ports" "forwarder")
old_mapping=$(load_toml_ports_mapping "$config_path")
tun_remote_addr=$(toml_get "$config_path" "tun" "remote_addr")
tun_name=$(toml_tun_name "$config_path")
if [[ "$is_tun" == "true" && -n "$forwarder" && "$forwarder" != "backhaul" ]]; then
remove_tun_port_forwarding "$old_mapping" "$forwarder" "$tun_remote_addr" "$config_name"
fi

awk -v newmap="$new_mapping" '
BEGIN { n = split(newmap, arr, ",") }
/^mapping = \[/ {
print
for (i=1;i<=n;i++) { if (length(arr[i])>0) printf "    \"%s\",\n", arr[i] }
inarr=1; next
}
inarr && /^\]/ { print; inarr=0; next }
inarr { next }
{ print }
' "$config_path" > "${config_path}.new" && mv "${config_path}.new" "$config_path"

if [[ "$is_tun" == "true" ]]; then
apply_tun_port_forwarding "$new_mapping" "$forwarder" "$tun_remote_addr" "$tun_name" "$config_name"
else
allow_forwarded_ports_firewall "$new_mapping" "$(toml_get "$config_path" "transport" "accept_udp")"
fi
systemctl restart "$service_name"
sleep 2
if systemctl is-active --quiet "$service_name"; then
colorize green "✔ Ports updated and service restarted."
rm -rf "$backup_dir"
else
colorize red "✘ Service failed to come back up; rolling back..."
restore_tunnel_backup "$backup_dir" "$config_path" "$service_path" "$service_name"
if systemctl is-active --quiet "$service_name"; then
colorize green "✔ Rollback succeeded."
else
colorize red "✘ Rollback also failed! Check logs manually: journalctl -eu ${service_name}"
fi
fi
press_key
}
edit_tunnel_ports() {
local config_path="$1" mode="$2" config_name service_name
if [[ "$mode" != "server" ]]; then
colorize red "This section is only available for the IRAN (server) side."
press_key
return
fi
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
while true; do
clear
colorize cyan "Forwarded Ports — ${config_name}" bold
echo ""
local current
current=$(load_toml_ports_mapping "$config_path")
local -a ports_arr=()
IFS=',' read -r -a ports_arr <<< "$current"
local i=1 p
for p in "${ports_arr[@]}"; do
[[ -n "$p" ]] && echo "  $i) $p" && ((i++))
done
[[ "$i" == "1" ]] && colorize yellow "  (no ports configured)"
echo ""
colorize green "a) Add a new port"
colorize red "d) Remove a port"
colorize yellow "e) Edit a port"
echo "0) Back"
read -r -p "Choice: " choice
case "$choice" in
a)
echo -ne "New port (e.g. 443 or 443=5000): "
read -r new_port
if [[ -n "$new_port" ]]; then
current="${current:+$current,}${new_port}"
apply_ports_mapping "$config_path" "$service_name" "$current"
fi
;;
d)
read -r -p "Row number to remove: " idx
if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx < i )); then
unset 'ports_arr[idx-1]'
current=$(IFS=,; echo "${ports_arr[*]}")
apply_ports_mapping "$config_path" "$service_name" "$current"
else
colorize red "Invalid choice"; sleep 1
fi
;;
e)
read -r -p "Row number to edit: " idx
if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx < i )); then
echo -ne "New value: "
read -r new_val
ports_arr[idx-1]="$new_val"
current=$(IFS=,; echo "${ports_arr[*]}")
apply_ports_mapping "$config_path" "$service_name" "$current"
else
colorize red "Invalid choice"; sleep 1
fi
;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}
edit_tunnel_full() {
local config_path="$1" mode="$2"
local config_name service_name service_path
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
service_path="${service_dir}/${service_name}"
local backup_dir
backup_dir=$(backup_tunnel "$config_path" "$service_path" "$config_name")
colorize green "Current config backed up: $backup_dir"
mv "$config_path" "${config_path}.editing"
load_toml_into_config "${backup_dir}/config.toml"
local old_forwarder="${CONFIG[forwarder]}" old_mapping="${CONFIG[ports_mapping]}" old_tun_remote_addr="${CONFIG[tun_remote_addr]}"
clear
colorize cyan "Edit Tunnel: ${config_name}" bold
echo ""
prompt_transport_section "$mode"
local is_tun="false" is_ipx="false"
[[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun="true"
[[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"
prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx"
prompt_ipx_section "$is_ipx" "$mode"
if [[ "$is_ipx" != "true" ]]; then
prompt_connection_section "$mode"
fi
prompt_security_section "$is_ipx"
prompt_accept_udp_section "${CONFIG[accept_udp]}"
prompt_mux_section "${CONFIG[transport_type]}"
prompt_tls_section "$mode" "${CONFIG[transport_type]}"
prompt_tuning_section "$is_ipx" "$is_tun"
prompt_logging_section
prompt_ports_section "$mode" "$is_tun"
rm -f "${config_path}.editing"
local new_port
if [[ "$mode" == "server" ]]; then
new_port=$(echo "${CONFIG[bind_addr]}" | grep -oP ':\K[0-9]+$')
else
new_port=$(echo "${CONFIG[remote_addr]}" | grep -oP ':\K[0-9]+$')
fi
[[ -z "$new_port" ]] && new_port="${CONFIG[tun_health_port]}"
local prefix new_config_name new_config_path new_service_name
[[ "$mode" == "server" ]] && prefix="iran" || prefix="kharej"
new_config_name="${prefix}${new_port}"
new_config_path="${config_dir}/${new_config_name}.toml"
new_service_name="backhaul-${new_config_name}.service"
generate_toml_config "$mode" "$new_config_path" "$is_tun" "$is_ipx"
if [[ "$new_config_name" != "$config_name" ]]; then
colorize yellow "Port changed; removing the old service and creating a new one..."
systemctl disable --now "$service_name" >/dev/null 2>&1
rm -f "$service_path"
systemctl daemon-reload
fi
if [[ "$is_tun" == "true" ]]; then
prepare_tun_ipx_kernel "$is_ipx" "${CONFIG[ipx_profile]}" "${CONFIG[tun_name]}"
fi
if [[ "$is_ipx" == "true" ]]; then
allow_ipx_protocol_firewall "${CONFIG[ipx_profile]}"
fi
if [[ -n "$old_forwarder" && "$old_forwarder" != "backhaul" ]]; then
remove_tun_port_forwarding "$old_mapping" "$old_forwarder" "$old_tun_remote_addr" "$config_name"
fi
if [[ "$mode" == "server" ]]; then
if [[ "$is_tun" == "true" ]]; then
apply_tun_port_forwarding "${CONFIG[ports_mapping]}" "${CONFIG[forwarder]}" "${CONFIG[tun_remote_addr]}" "${CONFIG[tun_name]}" "$new_config_name"
else
allow_forwarded_ports_firewall "${CONFIG[ports_mapping]}" "${CONFIG[accept_udp]}"
fi
fi
local peer_ip_for_meta="${CONFIG[peer_ip]}"
[[ -z "$peer_ip_for_meta" && "$is_ipx" == "true" ]] && peer_ip_for_meta="${CONFIG[ipx_dst_ip]}"
write_tunnel_meta "$new_config_name" "$peer_ip_for_meta" "${CONFIG[peer_ssh_port]}"
create_systemd_service "$prefix" "$new_port" "$new_config_path"
systemctl restart "$new_service_name"
sleep 2
if systemctl is-active --quiet "$new_service_name"; then
colorize green "✔ Changes applied successfully; service is healthy."
rm -rf "$backup_dir"
else
colorize red "✘ Service failed to come back up! Rolling back..."
systemctl disable --now "$new_service_name" >/dev/null 2>&1
rm -f "$new_config_path" "${service_dir}/${new_service_name}"
systemctl daemon-reload
restore_tunnel_backup "$backup_dir" "$config_path" "$service_path" "$service_name"
if systemctl is-active --quiet "$service_name"; then
colorize green "✔ Rollback succeeded, tunnel restored to its previous state."
else
colorize red "✘ Rollback also failed! Check logs manually: journalctl -eu ${service_name}"
fi
press_key
return 1
fi
echo ""
run_tunnel_diagnostics "$new_config_path"
}
edit_tunnel() {
local config_path="$1" config_name service_name role mode
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
role=$(tunnel_role "$config_path")
[[ "$role" == "server" ]] && mode="server" || mode="client"
clear
colorize cyan "Edit Tunnel: ${config_name}" bold
echo ""
colorize yellow "1) Full reconfiguration (IP/port/tunnel type/...)"
[[ "$role" == "server" ]] && colorize yellow "2) Manage forwarded ports"
colorize yellow "3) Enable/disable tunnel"
echo "0) Back"
read -r -p "Choice: " choice
case "$choice" in
1) edit_tunnel_full "$config_path" "$mode" ;;
2) [[ "$role" == "server" ]] && edit_tunnel_ports "$config_path" "$mode" ;;
3) toggle_tunnel_enabled "$service_name" ;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
}
benchmark_tcp_probe() {
local peer_ip="$1" port="$2" start end elapsed success=0 i
local latencies=()
for i in 1 2 3 4 5; do
start=$(date +%s%N)
if tcp_port_open "$peer_ip" "$port" 2; then
end=$(date +%s%N)
elapsed=$(( (end-start)/1000000 ))
latencies+=("$elapsed")
success=$((success+1))
fi
done
local n=${#latencies[@]}
if (( n == 0 )); then
echo "NA NA NA"
return
fi
local sum=0 l
for l in "${latencies[@]}"; do sum=$((sum+l)); done
local avg=$((sum/n))
local loss=$(( (5-success)*100/5 ))
local throughput="NA"
if command -v iperf3 &> /dev/null; then
local iperf_out
iperf_out=$(timeout 6 iperf3 -c "$peer_ip" -p 5201 -t 3 -J 2>/dev/null)
if [[ -n "$iperf_out" ]]; then
throughput=$(echo "$iperf_out" | grep -oP '"bits_per_second":\s*\K[0-9.]+' | tail -1)
[[ -n "$throughput" ]] && throughput=$(awk -v b="$throughput" 'BEGIN{printf "%.0f", b/1000000}')
fi
fi
echo "$avg $loss ${throughput:-NA}"
}
benchmark_icmp_probe() {
local peer_ip="$1" avg loss
read -r avg loss <<< "$(ping_stats "$peer_ip" 10)"
echo "$avg $loss NA"
}
benchmark_raw_protocol_probe() {
local peer_ip="$1" proto_num="$2"
if ! command -v hping3 &> /dev/null; then
echo "UNSUPPORTED"
return
fi
if timeout 5 hping3 -c 3 --rawip -H "$proto_num" "$peer_ip" 2>/dev/null | grep -q "bytes from"; then
echo "OK"
else
echo "BLOCKED"
fi
}
score_result() {
local latency="$1" loss="$2"
if [[ "$latency" == "NA" ]]; then echo 999999; return; fi
latency=$(printf "%.0f" "$latency")
echo $(( latency + loss*20 ))
}
status_label() {
local latency="$1" loss="$2"
if [[ "$latency" == "NA" ]]; then echo "Unusable"; return; fi
latency=$(printf "%.0f" "$latency")
if (( loss == 0 && latency < 80 )); then echo "Excellent"
elif (( loss <= 2 && latency < 150 )); then echo "Good"
elif (( loss <= 5 && latency < 300 )); then echo "Fair"
else echo "Poor"
fi
}
benchmark_tunnel_protocols() {
local config_path="$1" config_name peer_ip port
config_name=$(basename "${config_path%.toml}")
peer_ip=$(tunnel_peer_ip "$config_path" "$config_name")
if [[ -z "$peer_ip" ]]; then
colorize red "Peer IP is not set — set it from the Edit menu first."
press_key
return 1
fi
local port_source="tunnel"
port=$(tunnel_port_number "$config_path" "$(tunnel_role "$config_path")")
if [[ -z "$port" ]]; then
port=$(tunnel_peer_ssh_port "$config_name")
port_source="SSH"
fi

clear
colorize cyan "Protocol Benchmark — target: ${peer_ip}" bold
colorize yellow "Note: real throughput needs iperf3 running on the peer (iperf3 -s), otherwise it shows N/A. The GRE/IPIP test only checks whether the protocol passes through firewalls on the path (needs hping3) — it is not a live tunnel benchmark, since that needs matching config on both sides at once."
if [[ "$port_source" == "SSH" ]]; then
colorize yellow "No tunnel port on record for this config; the TCP test will probe the SSH port (${port}) instead, which may have its own separate access restrictions."
fi
echo ""

local -A RESULTS
colorize yellow "Testing TCP (port ${port})..."
RESULTS[tcp]=$(benchmark_tcp_probe "$peer_ip" "$port")
colorize yellow "Testing ICMP..."
RESULTS[icmp]=$(benchmark_icmp_probe "$peer_ip")
colorize yellow "Testing GRE (protocol reachability)..."
RESULTS[gre]=$(benchmark_raw_protocol_probe "$peer_ip" 47)
colorize yellow "Testing IPIP (protocol reachability)..."
RESULTS[ipip]=$(benchmark_raw_protocol_probe "$peer_ip" 4)

echo ""
colorize cyan "Test results:" bold
echo ""
local best_key="" best_score=999999999 i=1 key label lat loss thr status score
for key in tcp icmp; do
IFS=' ' read -r lat loss thr <<< "${RESULTS[$key]}"
[[ "$key" == "tcp" ]] && label="TCP Tunnel (port ${port})" || label="ICMP Tunnel"
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
for key in gre ipip; do
[[ "$key" == "gre" ]] && label="GRE Tunnel (IPX)" || label="IPIP Tunnel (IPX)"
echo "$i. $label"
case "${RESULTS[$key]}" in
OK) echo "   Status: protocol passes through the network path (real throughput/latency needs a live tunnel)" ;;
BLOCKED) echo "   Status: this protocol is blocked/filtered on one of the two sides" ;;
UNSUPPORTED) echo "   Status: hping3 is not installed, cannot test this protocol" ;;
esac
echo ""
((i++))
done

if [[ -n "$best_key" ]]; then
colorize green "Recommendation: ${best_key} is the best choice."
else
colorize yellow "Recommendation: none of the tested protocols were reliably reachable."
fi
write_tunnel_last_test "$config_name" "benchmark:${best_key:-none}"
echo ""
press_key
}
tunnel_detail_page() {
local config_path="$1"
local config_name service_name role transport ipx_profile peer_ip last_test last_time ports_count
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
while true; do
[[ -f "$config_path" ]] || return
role=$(tunnel_role "$config_path")
transport=$(toml_get "$config_path" "transport" "type")
ipx_profile=$(toml_get "$config_path" "ipx" "profile")
peer_ip=$(tunnel_peer_ip "$config_path" "$config_name")
clear
colorize cyan "Tunnel: ${config_name}" bold
echo ""
if systemctl is-active --quiet "$service_name"; then
colorize green "Status: Active"
else
colorize red "Status: Inactive"
fi
IFS='|' read -r last_test last_time <<< "$(read_tunnel_last_test "$config_name")"
echo "Last test: ${last_test} (${last_time})"
echo "Tunnel type: ${transport}${ipx_profile:+ / ipx:$ipx_profile}"
echo "Role: $([[ "$role" == "server" ]] && echo "IRAN (Server)" || echo "KHAREJ (Client)")"
if [[ -n "$peer_ip" ]]; then echo "Peer IP: ${peer_ip}"; else echo "Peer IP: not set"; fi
if [[ "$role" == "server" ]]; then
ports_count=$(load_toml_ports_mapping "$config_path" | tr ',' '\n' | grep -c .)
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
colorize magenta "3) Benchmark protocols"
echo "4) View service logs"
echo "5) View service status"
colorize yellow "6) Restart service"
colorize red "7) Remove this tunnel"
echo "0) Back"
echo ""
read -r -p "Choice: " choice
case "$choice" in
1) edit_tunnel "$config_path" ;;
2) run_tunnel_diagnostics "$config_path" ;;
3) benchmark_tunnel_protocols "$config_path" ;;
4) view_service_logs "$service_name" ;;
5) view_service_status "$service_name" ;;
6) restart_service "$service_name" ;;
7) destroy_tunnel "$config_path"; return ;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}
destroy_tunnel() {
config_path="$1"
local silent="${2:-}"
config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
service_path="$service_dir/$service_name"
local removed_tun_name removed_profile removed_forwarder removed_mapping removed_tun_remote_addr
removed_tun_name=$(toml_tun_name "$config_path")
removed_profile=$(toml_ipx_profile "$config_path")
removed_forwarder=$(toml_get "$config_path" "ports" "forwarder")
removed_mapping=$(load_toml_ports_mapping "$config_path")
removed_tun_remote_addr=$(toml_get "$config_path" "tun" "remote_addr")
if [[ -n "$removed_forwarder" && "$removed_forwarder" != "backhaul" ]]; then
remove_tun_port_forwarding "$removed_mapping" "$removed_forwarder" "$removed_tun_remote_addr" "$config_name"
fi
[ -f "$config_path" ] && rm -f "$config_path"
if [[ -f "$service_path" ]]; then
systemctl is-active --quiet "$service_name" && systemctl disable --now "$service_name" >/dev/null 2>&1
rm -f "$service_path"
fi
systemctl daemon-reload
if [[ -n "$removed_tun_name" ]] && command -v iptables &> /dev/null; then
iptables -D FORWARD -i "$removed_tun_name" -j ACCEPT 2>/dev/null
iptables -D FORWARD -o "$removed_tun_name" -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -o "$removed_tun_name" -j MASQUERADE 2>/dev/null
persist_iptables_rules
fi
if [[ -n "$removed_profile" ]] && ! profile_still_in_use "$removed_profile"; then
local proto="" mod=""
case "$removed_profile" in
gre) proto="47"; mod="ip_gre" ;;
ipip) proto="4"; mod="ipip" ;;
icmp) proto="icmp" ;;
esac
if [[ -n "$proto" ]] && command -v iptables &> /dev/null; then
iptables -D INPUT -p "$proto" -j ACCEPT 2>/dev/null
persist_iptables_rules
fi
if [[ "$removed_profile" == "gre" ]] && command -v ufw &> /dev/null; then
ufw delete allow proto gre from any to any comment "backhaul-ipx-gre" >/dev/null 2>&1
fi
if [[ -n "$mod" ]]; then
sed -i "/^${mod}\$/d" "/etc/modules-load.d/backhaul-tunnel.conf" 2>/dev/null
fi
fi
if [[ "$silent" != "--silent" ]]; then
if ! has_any_tun_config; then
colorize yellow "Note: no TUN tunnels remain on this server, but the ip_forward/rp_filter kernel settings applied earlier are system-wide and were left in place. Revert them manually via /etc/sysctl.d/99-backhaul-tunnel.conf if nothing else on this box needs them."
fi
echo
colorize green "Tunnel destroyed successfully!" bold
echo
press_key
else
colorize green "✔ Removed ${config_name}"
fi
}
restart_service() {
echo
colorize yellow "Restarting $1" bold
if systemctl list-units --type=service | grep -q "$1"; then
systemctl restart "$1"
colorize green "Service restarted successfully" bold
echo
else
colorize red "Service not found"
fi
press_key
}
view_service_logs() {
clear
journalctl -eu "$1" -f -o cat
}
view_service_status() {
clear
systemctl status "$1"
press_key
}
remove_core() {
if find "$config_dir" -type f -name "*.toml" | grep -q .; then
colorize red "Delete all services first."
sleep 3
return 1
fi
colorize yellow "Remove Backhaul-Core? (y/n)"
read -r confirm
if [[ $confirm == [yY] ]]; then
[[ -d "$config_dir" ]] && rm -rf "$config_dir"
colorize green "Backhaul-Core removed." bold
fi
press_key
}
uninstall_everything() {
clear
colorize red "═══════════════════════════════════════" bold
colorize red "  FULL UNINSTALL — THIS IS DESTRUCTIVE" bold
colorize red "═══════════════════════════════════════" bold
echo ""
echo "This will:"
echo "  - Stop and remove every configured tunnel and its firewall/forwarding rules"
echo "  - Remove the watchdog timer"
echo "  - Remove the journald size-limit and sysctl (ip_forward/rp_filter) drop-ins"
echo "  - Remove any HAProxy/IPVS config this panel created (not the packages themselves)"
echo "  - Delete ${config_dir} (all configs, certs, backups, the core binary)"
echo "  - Delete this panel script (${PANEL_PATH})"
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
colorize yellow "Removing all tunnels..."
local config_path
for config_path in "${config_dir}"/{iran,kharej}*.toml; do
[[ -f "$config_path" ]] || continue
destroy_tunnel "$config_path" --silent
done
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
colorize green "✔ Backhaul fully removed."
sleep 1
colorize yellow "Deleting this script..."
rm -f "$PANEL_PATH"
echo ""
colorize green "Done. Goodbye."
exit 0
}
update_script() {
local script_url="https://raw.githubusercontent.com/dr-hoseyn/tunnel-manager/main/backhaul.sh"
local target="$PANEL_PATH"
[[ -f "$target" ]] || target="$0"
colorize yellow "Updating management script..."
local tmp
tmp=$(mktemp "$(dirname "$target")/.backhaul.XXXXXX")
if curl -fsSL "$script_url" -o "$tmp"; then
chmod +x "$tmp"
mv -f "$tmp" "$target"
colorize green "✔ Script updated. Restarting..."
sleep 1
exec bash "$target"
else
colorize red "✘ Download failed."
rm -f "$tmp"
press_key
fi
}
configure_tunnel() {
[[ ! -d "$config_dir" ]] && {
colorize red "Install Backhaul-Core first."
press_key
return 1
}
clear
echo ""
colorize green "1) Configure IRAN (Server)" bold
colorize magenta "2) Configure KHAREJ (Client)" bold
echo ""
read -r -p "Enter your choice: " configure_choice
case "$configure_choice" in
1) configure_server "server" ;;
2) configure_server "client" ;;
*) colorize red "Invalid option!" && sleep 1 ;;
esac
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
1) configure_tunnel ;;
2) tunnel_management ;;
3) check_tunnel_status ;;
4) download_and_extract_backhaul "menu" ;;
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
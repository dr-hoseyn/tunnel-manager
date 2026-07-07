#!/usr/bin/env bash
# Shared utilities used by every tunnel core (colorize/prompt helpers, TOML
# reader, network probes, generic backup/restore, benchmark probes).
# Sourced by tunnel-manager.sh before any core module.

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
save_last_used() {
local key="$1" value="$2"
local file="${config_dir}/.last_used.conf"
[[ -z "$value" ]] && return 0
mkdir -p "$(dirname "$file")"
touch "$file"
grep -v "^${key}=" "$file" 2>/dev/null > "${file}.tmp"
echo "${key}=${value}" >> "${file}.tmp"
mv -f "${file}.tmp" "$file"
}
get_last_used() {
local key="$1" default="$2"
local file="${config_dir}/.last_used.conf"
local line
[[ -f "$file" ]] || { echo "$default"; return; }
line=$(grep "^${key}=" "$file" | tail -1)
if [[ -n "$line" ]]; then
echo "${line#*=}"
else
echo "$default"
fi
}
detect_default_interface() {
local iface
iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
if [[ -z "$iface" ]]; then
iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
fi
echo "$iface"
}
detect_public_ipv4() {
local ip
for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
ip=$(curl -fsS4 --max-time 2 "$url" 2>/dev/null | tr -d '[:space:]')
[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
done
return 1
}
detect_public_ipv6() {
local ip
for url in "https://api6.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
ip=$(curl -fsS6 --max-time 2 "$url" 2>/dev/null | tr -d '[:space:]')
[[ "$ip" == *:* ]] && { echo "$ip"; return 0; }
done
return 1
}
cert_days_remaining() {
local cert_file="$1"
[[ -f "$cert_file" ]] || { echo "-1"; return 1; }
local end_date end_epoch now_epoch
end_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2-)
[[ -z "$end_date" ]] && { echo "-1"; return 1; }
end_epoch=$(date -d "$end_date" +%s 2>/dev/null)
[[ -z "$end_epoch" ]] && { echo "-1"; return 1; }
now_epoch=$(date +%s)
echo $(( (end_epoch - now_epoch) / 86400 ))
}
ensure_cert_fresh() {
local cert_file="$1" key_file="$2"
local days
if [[ -f "$cert_file" && -f "$key_file" ]]; then
days=$(cert_days_remaining "$cert_file")
if (( days > 30 )); then
return 1
fi
colorize yellow "[*] TLS certificate expires in ${days} day(s), renewing..."
else
colorize yellow "[*] TLS certificate or key missing, generating self-signed Ed25519 cert..."
fi
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 -days 365 -sha256 -keyout "$key_file" -out "$cert_file" -subj "/CN=backhaul.com"
colorize green "[*] Generated $cert_file and $key_file"
return 0
}
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/tunnel-manager-ssh.conf"
fail2ban_ssh_status() {
[[ -f "$FAIL2BAN_JAIL_FILE" ]] && systemctl is-active --quiet fail2ban 2>/dev/null && echo "enabled" || echo "disabled"
}
enable_fail2ban_ssh_protection() {
if ! command -v fail2ban-client &> /dev/null; then
colorize yellow "Installing Fail2Ban..."
if command -v apt-get &> /dev/null; then
apt-get update -qq >/dev/null 2>&1
apt-get install -y fail2ban >/dev/null 2>&1
elif command -v dnf &> /dev/null; then
dnf install -y fail2ban >/dev/null 2>&1
elif command -v yum &> /dev/null; then
yum install -y fail2ban >/dev/null 2>&1
fi
fi
if ! command -v fail2ban-client &> /dev/null; then
colorize red "✘ Could not install Fail2Ban (unsupported package manager or no network)."
return 1
fi
mkdir -p "$(dirname "$FAIL2BAN_JAIL_FILE")"
cat > "$FAIL2BAN_JAIL_FILE" <<EOF
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban >/dev/null 2>&1
colorize green "✔ Fail2Ban SSH protection enabled (5 failed attempts in 10 min -> 1 hour ban)."
}
disable_fail2ban_ssh_protection() {
rm -f "$FAIL2BAN_JAIL_FILE"
systemctl restart fail2ban >/dev/null 2>&1
colorize yellow "Fail2Ban SSH jail removed (Fail2Ban itself stays installed/running for any other jails on the system)."
}
json_escape() {
local s="$1"
s="${s//\\/\\\\}"
s="${s//\"/\\\"}"
echo "$s"
}
# One JSON object per matching tunnel, one per line (caller joins with mapfile
# + IFS=,) — role is inferred from the iran/kharej filename prefix the same
# way every core's own listing UI already does it, active from systemctl.
emit_engine_tunnels_json() {
local dir="$1" engine="$2" prefix="$3" ext="$4"
local f name role active
for f in "${dir}"/iran*."${ext}" "${dir}"/kharej*."${ext}"; do
[[ -f "$f" ]] || continue
name=$(basename "${f%."${ext}"}")
if [[ "$name" == iran* ]]; then role="server"; else role="client"; fi
if systemctl is-active --quiet "${prefix}-${name}.service" 2>/dev/null; then active="true"; else active="false"; fi
printf '{"engine":"%s","name":"%s","role":"%s","active":%s}\n' "$(json_escape "$engine")" "$(json_escape "$name")" "$role" "$active"
done
}
cpu_usage_percent() {
[[ -r /proc/stat ]] || { echo "NA"; return 1; }
local -a f1 f2
read -r -a f1 < /proc/stat
sleep 0.3
read -r -a f2 < /proc/stat
local i total1=0 total2=0
for ((i = 1; i < ${#f1[@]}; i++)); do total1=$((total1 + f1[i])); done
for ((i = 1; i < ${#f2[@]}; i++)); do total2=$((total2 + f2[i])); done
local idle1=$((f1[4] + f1[5])) idle2=$((f2[4] + f2[5]))
local total_delta=$((total2 - total1)) idle_delta=$((idle2 - idle1))
(( total_delta <= 0 )) && { echo "0"; return; }
echo $(( (100 * (total_delta - idle_delta)) / total_delta ))
}
mem_usage_info() {
[[ -r /proc/meminfo ]] || { echo "NA NA NA"; return 1; }
local total avail
total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
[[ -z "$total" || -z "$avail" || "$total" -le 0 ]] && { echo "NA NA NA"; return 1; }
echo "$(( (total - avail) / 1024 )) $((total / 1024)) $(( (100 * (total - avail)) / total ))"
}
net_rate_kbps() {
local iface="$1"
[[ -r /proc/net/dev ]] || { echo "NA NA"; return 1; }
local rx1 tx1 rx2 tx2
read -r rx1 tx1 <<< "$(awk -v ifc="${iface}:" '$1==ifc{print $2, $10}' /proc/net/dev)"
[[ -z "$rx1" ]] && { echo "NA NA"; return 1; }
sleep 1
read -r rx2 tx2 <<< "$(awk -v ifc="${iface}:" '$1==ifc{print $2, $10}' /proc/net/dev)"
echo "$(( (rx2 - rx1) / 1024 )) $(( (tx2 - tx1) / 1024 ))"
}
count_tunnels_multi() {
local dir="$1" prefix="$2" ext="$3"
local total=0 active=0 f name svc
for f in "${dir}"/iran*."${ext}" "${dir}"/kharej*."${ext}"; do
[[ -f "$f" ]] || continue
((total++))
name=$(basename "${f%."${ext}"}")
svc="${prefix}-${name}.service"
systemctl is-active --quiet "$svc" 2>/dev/null && ((active++))
done
echo "$active $total"
}
persist_line_once() {
local line="$1"
local file="$2"
mkdir -p "$(dirname "$file")"
touch "$file"
grep -qxF "$line" "$file" || echo "$line" >> "$file"
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

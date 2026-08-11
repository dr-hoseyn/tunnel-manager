#!/usr/bin/env bash
# Low-overhead health telemetry and conservative root-cause classification for
# Backhaul TUN/IPX tunnels. Samples are written atomically per tunnel and the
# bounded history is deliberately plain TSV so it remains inspectable without
# a database or daemon.

# shellcheck disable=SC2034,SC2154 # Globals are shared by sourced panel modules.

TUNNEL_HEALTH_DIR="${config_dir}/.health"
HEALTH_HISTORY_LIMIT="${HEALTH_HISTORY_LIMIT:-288}"
HEALTH_SAMPLE_MAX_AGE="${HEALTH_SAMPLE_MAX_AGE:-600}"
HEALTH_AUTOMTU_MAX_AGE="${HEALTH_AUTOMTU_MAX_AGE:-120}"
HEALTH_SMALL_PAYLOAD="${HEALTH_SMALL_PAYLOAD:-64}"
HEALTH_PING_COUNT="${HEALTH_PING_COUNT:-4}"
HEALTH_BAD_LOSS="${HEALTH_BAD_LOSS:-25}"
HEALTH_DROP_DELTA="${HEALTH_DROP_DELTA:-10}"
HEALTH_CPU_PRESSURE="${HEALTH_CPU_PRESSURE:-85}"
HEALTH_MEMORY_PRESSURE="${HEALTH_MEMORY_PRESSURE:-95}"
HEALTH_CONNTRACK_PRESSURE="${HEALTH_CONNTRACK_PRESSURE:-90}"
HEALTH_JITTER_PRESSURE="${HEALTH_JITTER_PRESSURE:-5}"

health_safe_config_name() {
[[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]
}

health_latest_file() {
health_safe_config_name "$1" || return 1
printf '%s/%s.latest\n' "$TUNNEL_HEALTH_DIR" "$1"
}

health_history_file() {
health_safe_config_name "$1" || return 1
printf '%s/%s.history.tsv\n' "$TUNNEL_HEALTH_DIR" "$1"
}

health_state_get() {
local state_file="$1" key="$2" default_value="${3:-}" value
[[ "$key" =~ ^[a-z_]+$ ]] || { printf '%s' "$default_value"; return 1; }
value=$(grep -E "^${key}=" "$state_file" 2>/dev/null | tail -1 | cut -d= -f2-)
printf '%s' "${value:-$default_value}"
}

health_is_number() {
[[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

health_ge() {
health_is_number "$1" && awk -v value="$1" -v limit="$2" 'BEGIN { exit !(value >= limit) }'
}

health_gt() {
health_is_number "$1" && awk -v value="$1" -v limit="$2" 'BEGIN { exit !(value > limit) }'
}

health_delta() {
local current="$1" previous="$2"
if [[ "$current" =~ ^[0-9]+$ && "$previous" =~ ^[0-9]+$ ]] && (( current >= previous )); then
printf '%s\n' "$((current - previous))"
else
printf 'NA\n'
fi
}

health_sum_deltas() {
local first="$1" second="$2"
if [[ "$first" == "NA" && "$second" == "NA" ]]; then
printf 'NA\n'
return
fi
[[ "$first" =~ ^[0-9]+$ ]] || first=0
[[ "$second" =~ ^[0-9]+$ ]] || second=0
printf '%s\n' "$((first + second))"
}

health_rate_kbps() {
local delta_bytes="$1" elapsed="$2"
if [[ "$delta_bytes" =~ ^[0-9]+$ && "$elapsed" =~ ^[0-9]+$ ]] && (( elapsed > 0 )); then
printf '%s\n' "$((delta_bytes / elapsed / 1024))"
else
printf 'NA\n'
fi
}

health_ping_metrics() {
local iface="$1" host="$2" payload="$3" count="${4:-$HEALTH_PING_COUNT}" out avg loss jitter
if [[ -z "$iface" || -z "$host" || ! "$payload" =~ ^[0-9]+$ ]]; then
printf 'NA 100 NA\n'
return 0
fi
out=$(ping -I "$iface" -M "do" -s "$payload" -c "$count" -W 1 -w 5 "$host" 2>/dev/null || true)
loss=$(awk 'match($0, /[0-9]+% packet loss/) { text=substr($0,RSTART,RLENGTH); sub(/%.*/,"",text); print text; exit }' <<< "$out")
read -r avg jitter <<< "$(awk -F'= ' '/^(rtt|round-trip) / { split($2,a,"/"); print a[2], a[4]; exit }' <<< "$out")"
[[ "$loss" =~ ^[0-9]+$ ]] || loss=100
health_is_number "$avg" || avg="NA"
health_is_number "$jitter" || jitter="NA"
printf '%s %s %s\n' "$avg" "$loss" "$jitter"
}

health_iface_snapshot() {
local iface="$1" base key value output=""
if [[ ! "$iface" =~ ^[a-zA-Z0-9_.:-]{1,64}$ ]]; then
printf 'NA NA NA NA NA NA NA NA\n'
return 0
fi
base="/sys/class/net/${iface}/statistics"
for key in rx_bytes tx_bytes rx_packets tx_packets rx_errors tx_errors rx_dropped tx_dropped; do
if [[ -r "${base}/${key}" ]]; then
value=$(<"${base}/${key}")
[[ "$value" =~ ^[0-9]+$ ]] || value="NA"
else
value="NA"
fi
output+="${value} "
done
printf '%s\n' "${output% }"
}

health_route_iface() {
local host="$1"
[[ -n "$host" ]] || return 1
ip route get "$host" 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i=="dev") { print $(i+1); exit } }'
}

health_iface_exists() {
[[ -n "$1" && -d "/sys/class/net/$1" ]]
}

health_qdisc_drops() {
local iface="$1"
command -v tc &>/dev/null || { printf 'NA\n'; return 0; }
tc -s qdisc show dev "$iface" 2>/dev/null | awk '
match($0, /dropped [0-9]+/) {
text=substr($0,RSTART,RLENGTH); sub(/^dropped /,"",text); total+=text; found=1
}
END { if (found) print total; else print "NA" }
'
}

health_service_value() {
local service_name="$1" property="$2" value
value=$(systemctl show "$service_name" -p "$property" --value 2>/dev/null)
[[ "$value" =~ ^[0-9]+$ && "$value" != "18446744073709551615" ]] || value="NA"
printf '%s\n' "$value"
}

health_system_load_pct() {
local load_one cpu_count
read -r load_one _ < /proc/loadavg 2>/dev/null || { printf 'NA\n'; return 0; }
cpu_count=$(nproc 2>/dev/null || printf '1')
health_is_number "$load_one" && [[ "$cpu_count" =~ ^[0-9]+$ ]] && (( cpu_count > 0 )) || { printf 'NA\n'; return 0; }
awk -v load_value="$load_one" -v cpus="$cpu_count" 'BEGIN { printf "%.0f\n", load_value * 100 / cpus }'
}

health_memory_pct() {
local total available
total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
available=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
if [[ "$total" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] && (( total > 0 && available <= total )); then
printf '%s\n' "$((100 * (total - available) / total))"
else
printf 'NA\n'
fi
}

health_conntrack_pct() {
local count_file="/proc/sys/net/netfilter/nf_conntrack_count"
local max_file="/proc/sys/net/netfilter/nf_conntrack_max" count max
[[ -r "$count_file" && -r "$max_file" ]] || { printf 'NA\n'; return 0; }
count=$(<"$count_file"); max=$(<"$max_file")
if [[ "$count" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] && (( max > 0 )); then
printf '%s\n' "$((100 * count / max))"
else
printf 'NA\n'
fi
}

health_service_cpu_pct() {
local current="$1" previous="$2" elapsed="$3"
if [[ "$current" =~ ^[0-9]+$ && "$previous" =~ ^[0-9]+$ && "$elapsed" =~ ^[0-9]+$ ]] &&
(( current >= previous && elapsed > 0 )); then
awk -v delta="$((current - previous))" -v seconds="$elapsed" 'BEGIN { printf "%.0f\n", delta / (seconds * 1000000000) * 100 }'
else
printf 'NA\n'
fi
}

health_latency_spike() {
local current="$1" baseline="$2" jitter="$3"
health_is_number "$current" && health_is_number "$baseline" && health_is_number "$jitter" || return 1
awk -v current="$current" -v baseline="$baseline" -v jitter="$jitter" -v jitter_limit="$HEALTH_JITTER_PRESSURE" '
BEGIN { exit !(current > baseline * 2 + 20 && jitter >= jitter_limit) }
'
}

# Prints: classification|confidence|reason. Arguments are kept scalar so this
# policy can be unit-tested independently from Linux metric collection.
health_classify() {
local enabled="$1" active="$2" tun_exists="$3" restart_delta="$4"
local small_avg="$5" small_loss="$6" small_jitter="$7" large_avg="$8" large_loss="$9"
local outer_avg="${10}" outer_loss="${11}" tun_drop_delta="${12}" phys_drop_delta="${13}"
local phys_error_delta="${14}" qdisc_drop_delta="${15}" service_cpu="${16}" load_pct="${17}"
local memory_pct="${18}" conntrack_pct="${19}" baseline_rtt="${20}"

if [[ "$enabled" != "true" ]]; then
printf 'service-disabled|100|systemd-unit-disabled\n'; return
fi
if [[ "$active" != "true" ]]; then
printf 'service-failure|100|systemd-service-inactive\n'; return
fi
if [[ "$tun_exists" != "true" ]]; then
printf 'tunnel-interface-down|100|tun-interface-missing\n'; return
fi
if health_gt "$restart_delta" 0; then
printf 'service-restarting|95|systemd-restart-count-increased\n'; return
fi

if [[ "$small_avg" == "NA" ]] || health_ge "$small_loss" "$HEALTH_BAD_LOSS"; then
if health_ge "$phys_error_delta" 1 || health_ge "$phys_drop_delta" "$HEALTH_DROP_DELTA"; then
printf 'physical-interface-drops|90|underlay-interface-errors-or-drops\n'; return
fi
if health_ge "$service_cpu" "$HEALTH_CPU_PRESSURE" && health_ge "$load_pct" 100; then
printf 'cpu-saturation|85|service-cpu-and-system-load-high\n'; return
fi
if health_ge "$memory_pct" "$HEALTH_MEMORY_PRESSURE"; then
printf 'memory-pressure|85|system-memory-nearly-exhausted\n'; return
fi
if health_ge "$conntrack_pct" "$HEALTH_CONNTRACK_PRESSURE"; then
printf 'conntrack-pressure|85|conntrack-table-nearly-full\n'; return
fi
if health_ge "$tun_drop_delta" "$HEALTH_DROP_DELTA"; then
printf 'tunnel-interface-drops|85|tun-packet-drops-increased\n'; return
fi
if [[ "$outer_avg" != "NA" ]] && ! health_ge "$outer_loss" "$HEALTH_BAD_LOSS"; then
printf 'tunnel-path-failure|85|underlay-reachable-but-inner-tunnel-unhealthy\n'; return
fi
printf 'peer-or-underlay-unreachable|60|inner-and-underlay-control-probes-unhealthy\n'; return
fi

if health_ge "$phys_error_delta" 1 || health_ge "$phys_drop_delta" "$HEALTH_DROP_DELTA"; then
printf 'physical-interface-drops|80|underlay-interface-errors-or-drops\n'; return
fi
if health_ge "$tun_drop_delta" "$HEALTH_DROP_DELTA"; then
printf 'tunnel-interface-drops|80|tun-packet-drops-increased\n'; return
fi
if health_ge "$service_cpu" "$HEALTH_CPU_PRESSURE" && health_ge "$load_pct" 100; then
printf 'cpu-saturation|80|service-cpu-and-system-load-high\n'; return
fi
if health_ge "$memory_pct" "$HEALTH_MEMORY_PRESSURE"; then
printf 'memory-pressure|80|system-memory-nearly-exhausted\n'; return
fi
if health_ge "$conntrack_pct" "$HEALTH_CONNTRACK_PRESSURE"; then
printf 'conntrack-pressure|80|conntrack-table-nearly-full\n'; return
fi
if health_gt "$small_loss" 0 || health_latency_spike "$small_avg" "$baseline_rtt" "$small_jitter"; then
if health_ge "$qdisc_drop_delta" "$HEALTH_DROP_DELTA"; then
printf 'network-congestion|85|latency-or-loss-with-qdisc-drops\n'
else
printf 'network-congestion|70|small-packet-loss-or-latency-spike\n'
fi
return
fi
if [[ "$large_avg" == "NA" ]] || health_ge "$large_loss" "$HEALTH_BAD_LOSS"; then
printf 'mtu-suspected|85|small-probe-healthy-large-probe-unhealthy\n'; return
fi
printf 'healthy|95|all-health-gates-passed\n'
}

health_append_history() {
local history_file="$1" row="$2" tmp_file line_count
mkdir -p "$TUNNEL_HEALTH_DIR" || return 1
chmod 700 "$TUNNEL_HEALTH_DIR"
if [[ ! -f "$history_file" ]]; then
printf 'epoch\tclass\tconfidence\treason\tsmall_avg\tsmall_loss\tsmall_jitter\tlarge_avg\tlarge_loss\touter_avg\touter_loss\trx_kbps\ttx_kbps\ttun_drop_delta\tphys_drop_delta\tphys_error_delta\tqdisc_drop_delta\tservice_cpu_pct\tservice_mem_mb\trestart_delta\tconntrack_pct\tload_pct\tmemory_pct\tmtu\n' > "$history_file" || return 1
fi
printf '%s\n' "$row" >> "$history_file" || return 1
chmod 600 "$history_file"
line_count=$(wc -l < "$history_file")
if (( line_count > HEALTH_HISTORY_LIMIT + 1 )); then
tmp_file=$(mktemp "${history_file}.XXXXXX") || return 1
{
head -1 "$history_file"
tail -n "$HEALTH_HISTORY_LIMIT" "$history_file"
} > "$tmp_file"
chmod 600 "$tmp_file"
mv -f "$tmp_file" "$history_file"
fi
}

health_collect_locked() {
local config_path="$1" mode="$2" config_name service_name latest_file history_file now previous_epoch elapsed
local enabled="false" active="false" tun_name inner_peer outer_peer physical_iface current_mtu large_payload
local small_avg="NA" small_loss=100 small_jitter="NA" large_avg="NA" large_loss=100
local outer_avg="NA" outer_loss=100 outer_jitter="NA" tun_exists="false"
local tun_rx_bytes tun_tx_bytes tun_rx_packets tun_tx_packets tun_rx_errors tun_tx_errors tun_rx_dropped tun_tx_dropped
local phy_rx_bytes phy_tx_bytes phy_rx_packets phy_tx_packets phy_rx_errors phy_tx_errors phy_rx_dropped phy_tx_dropped
local prev_tun_rx_bytes prev_tun_tx_bytes prev_tun_rx_dropped prev_tun_tx_dropped prev_tun_rx_errors prev_tun_tx_errors
local prev_phy_rx_dropped prev_phy_tx_dropped prev_phy_rx_errors prev_phy_tx_errors
local tun_rx_delta tun_tx_delta tun_rx_kbps tun_tx_kbps tun_rx_drop_delta tun_tx_drop_delta tun_drop_delta
local tun_rx_error_delta tun_tx_error_delta phy_rx_drop_delta phy_tx_drop_delta phys_drop_delta
local phy_rx_error_delta phy_tx_error_delta phys_error_delta qdisc_now qdisc_prev qdisc_drop_delta
local cpu_now cpu_prev service_cpu service_memory service_ingress service_egress prev_ingress prev_egress
local ingress_delta egress_delta service_rx_kbps service_tx_kbps restart_now restart_prev restart_delta
local conntrack_pct load_pct memory_pct baseline_rtt classification confidence reason raw_result
local previous_class previous_raw raw_streak tmp_file history_row

config_name=$(basename "${config_path%.toml}")
health_safe_config_name "$config_name" || return 1
service_name="backhaul-${config_name}.service"
latest_file=$(health_latest_file "$config_name") || return 1
history_file=$(health_history_file "$config_name") || return 1
mkdir -p "$TUNNEL_HEALTH_DIR" || return 1
chmod 700 "$TUNNEL_HEALTH_DIR"

now=$(date +%s)
previous_epoch=$(health_state_get "$latest_file" epoch "0")
[[ "$previous_epoch" =~ ^[0-9]+$ ]] || previous_epoch=0
elapsed=$((now - previous_epoch)); (( elapsed > 0 )) || elapsed=1
service_should_run "$service_name" && enabled="true"
systemctl is-active --quiet "$service_name" 2>/dev/null && active="true"

tun_name=$(toml_get "$config_path" tun name)
inner_peer=$(toml_get "$config_path" tun remote_addr); inner_peer="${inner_peer%/*}"
outer_peer=$(toml_get "$config_path" ipx dst_ip)
current_mtu=$(toml_get "$config_path" tun mtu)
[[ "$current_mtu" =~ ^[0-9]+$ ]] || current_mtu="NA"
health_iface_exists "$tun_name" && tun_exists="true"
physical_iface=$(health_route_iface "$outer_peer" || true)
[[ -n "$physical_iface" ]] || physical_iface=$(detect_default_interface)

read -r tun_rx_bytes tun_tx_bytes tun_rx_packets tun_tx_packets tun_rx_errors tun_tx_errors tun_rx_dropped tun_tx_dropped <<< "$(health_iface_snapshot "$tun_name")"
read -r phy_rx_bytes phy_tx_bytes phy_rx_packets phy_tx_packets phy_rx_errors phy_tx_errors phy_rx_dropped phy_tx_dropped <<< "$(health_iface_snapshot "$physical_iface")"

prev_tun_rx_bytes=$(health_state_get "$latest_file" tun_rx_bytes "NA")
prev_tun_tx_bytes=$(health_state_get "$latest_file" tun_tx_bytes "NA")
prev_tun_rx_dropped=$(health_state_get "$latest_file" tun_rx_dropped "NA")
prev_tun_tx_dropped=$(health_state_get "$latest_file" tun_tx_dropped "NA")
prev_tun_rx_errors=$(health_state_get "$latest_file" tun_rx_errors "NA")
prev_tun_tx_errors=$(health_state_get "$latest_file" tun_tx_errors "NA")
prev_phy_rx_dropped=$(health_state_get "$latest_file" phy_rx_dropped "NA")
prev_phy_tx_dropped=$(health_state_get "$latest_file" phy_tx_dropped "NA")
prev_phy_rx_errors=$(health_state_get "$latest_file" phy_rx_errors "NA")
prev_phy_tx_errors=$(health_state_get "$latest_file" phy_tx_errors "NA")

tun_rx_delta=$(health_delta "$tun_rx_bytes" "$prev_tun_rx_bytes")
tun_tx_delta=$(health_delta "$tun_tx_bytes" "$prev_tun_tx_bytes")
tun_rx_kbps=$(health_rate_kbps "$tun_rx_delta" "$elapsed")
tun_tx_kbps=$(health_rate_kbps "$tun_tx_delta" "$elapsed")
tun_rx_drop_delta=$(health_delta "$tun_rx_dropped" "$prev_tun_rx_dropped")
tun_tx_drop_delta=$(health_delta "$tun_tx_dropped" "$prev_tun_tx_dropped")
tun_drop_delta=$(health_sum_deltas "$tun_rx_drop_delta" "$tun_tx_drop_delta")
tun_rx_error_delta=$(health_delta "$tun_rx_errors" "$prev_tun_rx_errors")
tun_tx_error_delta=$(health_delta "$tun_tx_errors" "$prev_tun_tx_errors")
phy_rx_drop_delta=$(health_delta "$phy_rx_dropped" "$prev_phy_rx_dropped")
phy_tx_drop_delta=$(health_delta "$phy_tx_dropped" "$prev_phy_tx_dropped")
phys_drop_delta=$(health_sum_deltas "$phy_rx_drop_delta" "$phy_tx_drop_delta")
phy_rx_error_delta=$(health_delta "$phy_rx_errors" "$prev_phy_rx_errors")
phy_tx_error_delta=$(health_delta "$phy_tx_errors" "$prev_phy_tx_errors")
phys_error_delta=$(health_sum_deltas "$phy_rx_error_delta" "$phy_tx_error_delta")

qdisc_now=$(health_qdisc_drops "$physical_iface")
qdisc_prev=$(health_state_get "$latest_file" qdisc_drops "NA")
qdisc_drop_delta=$(health_delta "$qdisc_now" "$qdisc_prev")

cpu_now=$(health_service_value "$service_name" CPUUsageNSec)
cpu_prev=$(health_state_get "$latest_file" service_cpu_nsec "NA")
service_cpu=$(health_service_cpu_pct "$cpu_now" "$cpu_prev" "$elapsed")
service_memory=$(health_service_value "$service_name" MemoryCurrent)
if [[ "$service_memory" =~ ^[0-9]+$ ]]; then service_memory=$((service_memory / 1024 / 1024)); fi
service_ingress=$(health_service_value "$service_name" IPIngressBytes)
service_egress=$(health_service_value "$service_name" IPEgressBytes)
prev_ingress=$(health_state_get "$latest_file" service_ingress_bytes "NA")
prev_egress=$(health_state_get "$latest_file" service_egress_bytes "NA")
ingress_delta=$(health_delta "$service_ingress" "$prev_ingress")
egress_delta=$(health_delta "$service_egress" "$prev_egress")
service_rx_kbps=$(health_rate_kbps "$ingress_delta" "$elapsed")
service_tx_kbps=$(health_rate_kbps "$egress_delta" "$elapsed")
restart_now=$(health_service_value "$service_name" NRestarts)
restart_prev=$(health_state_get "$latest_file" service_restarts "NA")
restart_delta=$(health_delta "$restart_now" "$restart_prev")
conntrack_pct=$(health_conntrack_pct)
load_pct=$(health_system_load_pct)
memory_pct=$(health_memory_pct)

if [[ "$active" == "true" && "$tun_exists" == "true" && "$current_mtu" =~ ^[0-9]+$ ]]; then
read -r small_avg small_loss small_jitter <<< "$(health_ping_metrics "$tun_name" "$inner_peer" "$HEALTH_SMALL_PAYLOAD")"
large_payload=$((current_mtu - 28)); (( large_payload >= HEALTH_SMALL_PAYLOAD )) || large_payload="$HEALTH_SMALL_PAYLOAD"
read -r large_avg large_loss _ <<< "$(health_ping_metrics "$tun_name" "$inner_peer" "$large_payload")"
fi
if [[ "$active" == "true" && -n "$physical_iface" && -n "$outer_peer" ]]; then
read -r outer_avg outer_loss outer_jitter <<< "$(health_ping_metrics "$physical_iface" "$outer_peer" "$HEALTH_SMALL_PAYLOAD" 2)"
fi

baseline_rtt=$(health_state_get "$latest_file" baseline_rtt "NA")
raw_result=$(health_classify "$enabled" "$active" "$tun_exists" "$restart_delta" \
"$small_avg" "$small_loss" "$small_jitter" "$large_avg" "$large_loss" "$outer_avg" "$outer_loss" \
"$tun_drop_delta" "$phys_drop_delta" "$phys_error_delta" "$qdisc_drop_delta" "$service_cpu" \
"$load_pct" "$memory_pct" "$conntrack_pct" "$baseline_rtt")
IFS='|' read -r classification confidence reason <<< "$raw_result"

previous_raw=$(health_state_get "$latest_file" raw_class "none")
raw_streak=$(health_state_get "$latest_file" raw_streak "0")
[[ "$raw_streak" =~ ^[0-9]+$ ]] || raw_streak=0
if [[ "$classification" == "$previous_raw" ]]; then raw_streak=$((raw_streak + 1)); else raw_streak=1; fi
if (( raw_streak > 1 && confidence < 99 )); then
confidence=$((confidence + (raw_streak > 3 ? 4 : raw_streak - 1) * 2))
(( confidence > 99 )) && confidence=99
fi
if [[ "$small_avg" != "NA" && "$small_loss" == "0" ]]; then
if health_is_number "$baseline_rtt"; then
baseline_rtt=$(awk -v old="$baseline_rtt" -v current="$small_avg" 'BEGIN { printf "%.2f", old * 0.8 + current * 0.2 }')
else
baseline_rtt="$small_avg"
fi
fi

previous_class=$(health_state_get "$latest_file" classification "none")
tmp_file=$(mktemp "${latest_file}.XXXXXX") || return 1
{
printf 'version=1\n'
printf 'epoch=%s\nclassification=%s\nconfidence=%s\nreason=%s\n' "$now" "$classification" "$confidence" "$reason"
printf 'raw_class=%s\nraw_streak=%s\nbaseline_rtt=%s\n' "$classification" "$raw_streak" "$baseline_rtt"
printf 'service_enabled=%s\nservice_active=%s\ntun_exists=%s\n' "$enabled" "$active" "$tun_exists"
printf 'tun_name=%s\nphysical_iface=%s\ncurrent_mtu=%s\n' "$tun_name" "$physical_iface" "$current_mtu"
printf 'small_avg=%s\nsmall_loss=%s\nsmall_jitter=%s\n' "$small_avg" "$small_loss" "$small_jitter"
printf 'large_avg=%s\nlarge_loss=%s\nouter_avg=%s\nouter_loss=%s\nouter_jitter=%s\n' "$large_avg" "$large_loss" "$outer_avg" "$outer_loss" "$outer_jitter"
printf 'tun_rx_kbps=%s\ntun_tx_kbps=%s\nservice_rx_kbps=%s\nservice_tx_kbps=%s\n' "$tun_rx_kbps" "$tun_tx_kbps" "$service_rx_kbps" "$service_tx_kbps"
printf 'tun_drop_delta=%s\nphys_drop_delta=%s\nphys_error_delta=%s\nqdisc_drop_delta=%s\n' "$tun_drop_delta" "$phys_drop_delta" "$phys_error_delta" "$qdisc_drop_delta"
printf 'service_cpu_pct=%s\nservice_mem_mb=%s\nrestart_delta=%s\nconntrack_pct=%s\nload_pct=%s\nmemory_pct=%s\n' "$service_cpu" "$service_memory" "$restart_delta" "$conntrack_pct" "$load_pct" "$memory_pct"
printf 'tun_rx_bytes=%s\ntun_tx_bytes=%s\ntun_rx_errors=%s\ntun_tx_errors=%s\ntun_rx_dropped=%s\ntun_tx_dropped=%s\n' "$tun_rx_bytes" "$tun_tx_bytes" "$tun_rx_errors" "$tun_tx_errors" "$tun_rx_dropped" "$tun_tx_dropped"
printf 'phy_rx_dropped=%s\nphy_tx_dropped=%s\nphy_rx_errors=%s\nphy_tx_errors=%s\nqdisc_drops=%s\n' "$phy_rx_dropped" "$phy_tx_dropped" "$phy_rx_errors" "$phy_tx_errors" "$qdisc_now"
printf 'service_cpu_nsec=%s\nservice_ingress_bytes=%s\nservice_egress_bytes=%s\nservice_restarts=%s\n' "$cpu_now" "$service_ingress" "$service_egress" "$restart_now"
} > "$tmp_file"
chmod 600 "$tmp_file"
mv -f "$tmp_file" "$latest_file"

history_row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
"$now" "$classification" "$confidence" "$reason" "$small_avg" "$small_loss" "$small_jitter" "$large_avg" "$large_loss" "$outer_avg" "$outer_loss" \
"$tun_rx_kbps" "$tun_tx_kbps" "$tun_drop_delta" "$phys_drop_delta" "$phys_error_delta" "$qdisc_drop_delta" "$service_cpu" "$service_memory" "$restart_delta" "$conntrack_pct" "$load_pct" "$memory_pct" "$current_mtu")
health_append_history "$history_file" "$history_row" || return 1

if [[ "$classification" != "$previous_class" ]]; then
if [[ "$classification" != "healthy" || "$previous_class" != "none" ]]; then
logger -t backhaul-health "${config_name}: ${previous_class} -> ${classification} (${confidence}%, ${reason})" 2>/dev/null || true
fi
fi
if [[ "$mode" == "manual" ]]; then
printf '%s|%s|%s\n' "$classification" "$confidence" "$reason"
fi
}

tunnel_health_run() {
local config_path="$1" mode="${2:-watchdog}" config_name latest_file lock_fd result
[[ -f "$config_path" ]] || return 1
grep -q '^\[ipx\]$' "$config_path" 2>/dev/null || return 0
config_name=$(basename "${config_path%.toml}")
latest_file=$(health_latest_file "$config_name") || return 1
mkdir -p "$TUNNEL_HEALTH_DIR" || return 1
if command -v flock &>/dev/null; then
exec {lock_fd}>"${latest_file}.lock"
flock -n "$lock_fd" || return 0
fi
if health_collect_locked "$config_path" "$mode"; then result=0; else result=$?; fi
if [[ -n "${lock_fd:-}" ]]; then
flock -u "$lock_fd" 2>/dev/null || true
exec {lock_fd}>&-
fi
return "$result"
}

tunnel_health_delete() {
local config_name="$1" latest_file history_file lock_fd
latest_file=$(health_latest_file "$config_name") || return 1
history_file=$(health_history_file "$config_name") || return 1
[[ -d "$TUNNEL_HEALTH_DIR" ]] || return 0
if command -v flock &>/dev/null; then
exec {lock_fd}>"${latest_file}.lock"
flock -w 5 "$lock_fd" || return 1
fi
rm -f "$latest_file" "$history_file"
if [[ -n "${lock_fd:-}" ]]; then
flock -u "$lock_fd" 2>/dev/null || true
exec {lock_fd}>&-
fi
}

tunnel_health_invalidate() {
local config_name="$1" latest_file lock_fd
latest_file=$(health_latest_file "$config_name") || return 1
[[ -d "$TUNNEL_HEALTH_DIR" ]] || return 0
if command -v flock &>/dev/null; then
exec {lock_fd}>"${latest_file}.lock"
flock -w 5 "$lock_fd" || return 1
fi
rm -f "$latest_file"
if [[ -n "${lock_fd:-}" ]]; then
flock -u "$lock_fd" 2>/dev/null || true
exec {lock_fd}>&-
fi
}

tunnel_health_summary() {
local config_name="$1" latest_file classification confidence reason epoch now age age_seconds
latest_file=$(health_latest_file "$config_name") || return 1
classification=$(health_state_get "$latest_file" classification "never-sampled")
confidence=$(health_state_get "$latest_file" confidence "0")
reason=$(health_state_get "$latest_file" reason "no-health-sample")
epoch=$(health_state_get "$latest_file" epoch "0")
now=$(date +%s)
if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 && now >= epoch )); then
age_seconds=$((now - epoch))
age="${age_seconds}s ago"
(( age_seconds > HEALTH_SAMPLE_MAX_AGE )) && age+="; stale"
else
age="never"
fi
printf '%s (%s%%) | %s | %s\n' "$classification" "$confidence" "$reason" "$age"
}

tunnel_health_ensure_fresh() {
local config_path="$1" config_name latest_file epoch now
config_name=$(basename "${config_path%.toml}")
latest_file=$(health_latest_file "$config_name") || return 1
epoch=$(health_state_get "$latest_file" epoch "0")
now=$(date +%s)
if [[ ! "$epoch" =~ ^[0-9]+$ ]] || (( epoch <= 0 || now < epoch || now - epoch > HEALTH_AUTOMTU_MAX_AGE )); then
tunnel_health_run "$config_path" auto-mtu >/dev/null
fi
}

HEALTH_GATE_REASON=""
tunnel_health_automtu_gate() {
local config_path="$1" config_name latest_file classification epoch sample_mtu current_mtu now
config_name=$(basename "${config_path%.toml}")
latest_file=$(health_latest_file "$config_name") || { HEALTH_GATE_REASON="invalid-health-state"; return 1; }
classification=$(health_state_get "$latest_file" classification "unknown")
epoch=$(health_state_get "$latest_file" epoch "0")
sample_mtu=$(health_state_get "$latest_file" current_mtu "NA")
current_mtu=$(toml_get "$config_path" tun mtu)
now=$(date +%s)
if [[ ! "$epoch" =~ ^[0-9]+$ ]] || (( epoch <= 0 || now < epoch || now - epoch > HEALTH_AUTOMTU_MAX_AGE )); then
HEALTH_GATE_REASON="health-sample-stale"
return 1
fi
if [[ "$sample_mtu" != "$current_mtu" ]]; then
HEALTH_GATE_REASON="health-sample-mtu-mismatch"
return 1
fi
case "$classification" in
healthy|mtu-suspected) HEALTH_GATE_REASON="$classification"; return 0 ;;
*) HEALTH_GATE_REASON="health-class-${classification}"; return 1 ;;
esac
}

tunnel_health_show_latest() {
local config_name="$1" latest_file
latest_file=$(health_latest_file "$config_name") || return 1
if [[ ! -f "$latest_file" ]]; then
colorize yellow "No health sample exists yet."
return 1
fi
echo "Classification: $(health_state_get "$latest_file" classification unknown) ($(health_state_get "$latest_file" confidence 0)%)"
echo "Reason:         $(health_state_get "$latest_file" reason unknown)"
echo "Control probe:  avg=$(health_state_get "$latest_file" small_avg NA)ms loss=$(health_state_get "$latest_file" small_loss NA)% jitter=$(health_state_get "$latest_file" small_jitter NA)ms"
echo "Large probe:    avg=$(health_state_get "$latest_file" large_avg NA)ms loss=$(health_state_get "$latest_file" large_loss NA)%"
echo "Underlay probe: avg=$(health_state_get "$latest_file" outer_avg NA)ms loss=$(health_state_get "$latest_file" outer_loss NA)%"
echo "TUN traffic:    RX=$(health_state_get "$latest_file" tun_rx_kbps NA) KB/s TX=$(health_state_get "$latest_file" tun_tx_kbps NA) KB/s"
echo "Service traffic: RX=$(health_state_get "$latest_file" service_rx_kbps NA) KB/s TX=$(health_state_get "$latest_file" service_tx_kbps NA) KB/s"
echo "Drops/errors:   tun=$(health_state_get "$latest_file" tun_drop_delta NA) physical=$(health_state_get "$latest_file" phys_drop_delta NA)/$(health_state_get "$latest_file" phys_error_delta NA) qdisc=$(health_state_get "$latest_file" qdisc_drop_delta NA)"
echo "Resources:      service CPU=$(health_state_get "$latest_file" service_cpu_pct NA)% RAM=$(health_state_get "$latest_file" service_mem_mb NA)MB system load=$(health_state_get "$latest_file" load_pct NA)% memory=$(health_state_get "$latest_file" memory_pct NA)% conntrack=$(health_state_get "$latest_file" conntrack_pct NA)%"
echo "MTU:            $(health_state_get "$latest_file" current_mtu NA)"
}

tunnel_health_show_history() {
local config_name="$1" limit="${2:-12}" history_file epoch classification confidence reason small_avg small_loss small_jitter
local large_avg large_loss outer_avg outer_loss rx_kbps tx_kbps tun_drop phys_drop phys_error qdisc_drop
local service_cpu service_mem restart_delta conntrack load memory mtu timestamp
history_file=$(health_history_file "$config_name") || return 1
if [[ ! -f "$history_file" ]]; then
colorize yellow "No health history exists yet."
return 1
fi
tail -n "$limit" "$history_file" | while IFS=$'\t' read -r epoch classification confidence reason small_avg small_loss small_jitter large_avg large_loss outer_avg outer_loss rx_kbps tx_kbps tun_drop phys_drop phys_error qdisc_drop service_cpu service_mem restart_delta conntrack load memory mtu; do
[[ "$epoch" =~ ^[0-9]+$ ]] || continue
timestamp=$(date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$epoch")
printf '%s | %-29s %3s%% | RTT %sms loss %s%% jitter %sms | large %s%% | RX/TX %s/%s KB/s | MTU %s\n' \
"$timestamp" "$classification" "$confidence" "$small_avg" "$small_loss" "$small_jitter" "$large_loss" "$rx_kbps" "$tx_kbps" "$mtu"
done
}

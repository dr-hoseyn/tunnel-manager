#!/usr/bin/env bash
# Conservative adaptive MTU controller for Backhaul TUN/IPX tunnels.
# It is intentionally opt-in per tunnel and follows a probe/confirm/rollback
# state machine.  A small control probe must be healthy before packet-size
# failures are treated as MTU evidence.

# shellcheck disable=SC2034,SC2154 # Globals are shared with the sourced Backhaul module.

AUTOMTU_STATE_DIR="${config_dir}/.auto-mtu"
AUTOMTU_HARD_MIN="${AUTOMTU_HARD_MIN:-1000}"
AUTOMTU_HARD_MAX="${AUTOMTU_HARD_MAX:-1500}"
AUTOMTU_DEFAULT_MIN="${AUTOMTU_DEFAULT_MIN:-1200}"
AUTOMTU_DEFAULT_MAX="${AUTOMTU_DEFAULT_MAX:-1420}"
AUTOMTU_DEFAULT_STEP="${AUTOMTU_DEFAULT_STEP:-20}"
AUTOMTU_GOOD_STREAK_REQUIRED="${AUTOMTU_GOOD_STREAK_REQUIRED:-3}"
AUTOMTU_BAD_STREAK_REQUIRED="${AUTOMTU_BAD_STREAK_REQUIRED:-2}"
AUTOMTU_CHANGE_COOLDOWN="${AUTOMTU_CHANGE_COOLDOWN:-21600}"
AUTOMTU_REJECT_COOLDOWN="${AUTOMTU_REJECT_COOLDOWN:-86400}"
AUTOMTU_MIN_SERVICE_UPTIME="${AUTOMTU_MIN_SERVICE_UPTIME:-600}"
AUTOMTU_MAX_RATE_BPS="${AUTOMTU_MAX_RATE_BPS:-262144}"
AUTOMTU_TRAFFIC_SAMPLE_SECONDS="${AUTOMTU_TRAFFIC_SAMPLE_SECONDS:-1}"
AUTOMTU_SETTLE_SECONDS="${AUTOMTU_SETTLE_SECONDS:-5}"
AUTOMTU_SMALL_PAYLOAD="${AUTOMTU_SMALL_PAYLOAD:-64}"
AUTOMTU_SMALL_MAX_LOSS="${AUTOMTU_SMALL_MAX_LOSS:-10}"
AUTOMTU_LARGE_BAD_LOSS="${AUTOMTU_LARGE_BAD_LOSS:-20}"
AUTOMTU_LARGE_GOOD_LOSS="${AUTOMTU_LARGE_GOOD_LOSS:-5}"

automtu_state_file() {
local config_name="$1"
[[ "$config_name" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
printf '%s/%s.state\n' "$AUTOMTU_STATE_DIR" "$config_name"
}

automtu_state_get() {
local state_file="$1" key="$2" default_value="${3:-}" value
[[ "$key" =~ ^[a-z_]+$ ]] || { printf '%s' "$default_value"; return 1; }
value=$(grep -E "^${key}=" "$state_file" 2>/dev/null | tail -1 | cut -d= -f2-)
printf '%s' "${value:-$default_value}"
}

automtu_state_set() {
local state_file="$1" key="$2" value="$3" tmp_file
[[ "$key" =~ ^[a-z_]+$ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
mkdir -p "$AUTOMTU_STATE_DIR" || return 1
chmod 700 "$AUTOMTU_STATE_DIR"
tmp_file=$(mktemp "${state_file}.XXXXXX") || return 1
if [[ -f "$state_file" ]]; then
awk -F= -v wanted="$key" '$1 != wanted { print }' "$state_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
fi
printf '%s=%s\n' "$key" "$value" >> "$tmp_file"
chmod 600 "$tmp_file"
mv -f "$tmp_file" "$state_file"
}

automtu_state_unset() {
local state_file="$1" key="$2" tmp_file
[[ "$key" =~ ^[a-z_]+$ ]] || return 1
[[ -f "$state_file" ]] || return 0
tmp_file=$(mktemp "${state_file}.XXXXXX") || return 1
awk -F= -v wanted="$key" '$1 != wanted { print }' "$state_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
chmod 600 "$tmp_file"
mv -f "$tmp_file" "$state_file"
}

automtu_validate_settings() {
local min_mtu="$1" max_mtu="$2" step="$3"
[[ "$min_mtu" =~ ^[0-9]+$ && "$max_mtu" =~ ^[0-9]+$ && "$step" =~ ^[0-9]+$ ]] || return 1
(( min_mtu >= AUTOMTU_HARD_MIN && max_mtu <= AUTOMTU_HARD_MAX && min_mtu < max_mtu )) || return 1
(( step >= 8 && step <= 100 && step < max_mtu - min_mtu ))
}

automtu_save_settings() {
local config_name="$1" enabled="$2" min_mtu="$3" max_mtu="$4" step="$5" state_file dynamic_max
[[ "$enabled" == "true" || "$enabled" == "false" ]] || return 1
automtu_validate_settings "$min_mtu" "$max_mtu" "$step" || return 1
state_file=$(automtu_state_file "$config_name") || return 1
automtu_state_set "$state_file" enabled "$enabled" || return 1
automtu_state_set "$state_file" min_mtu "$min_mtu" || return 1
automtu_state_set "$state_file" max_mtu "$max_mtu" || return 1
automtu_state_set "$state_file" step "$step" || return 1
dynamic_max=$(automtu_state_get "$state_file" dynamic_max "$max_mtu")
if [[ ! "$dynamic_max" =~ ^[0-9]+$ ]] || (( dynamic_max > max_mtu || dynamic_max < min_mtu )); then
automtu_state_set "$state_file" dynamic_max "$max_mtu" || return 1
fi
return 0
}

automtu_load_settings_into_config() {
local config_name="$1" state_file
state_file=$(automtu_state_file "$config_name") || return 1
CONFIG[smart_auto_mtu]=$(automtu_state_get "$state_file" enabled "false")
CONFIG[smart_mtu_min]=$(automtu_state_get "$state_file" min_mtu "$AUTOMTU_DEFAULT_MIN")
CONFIG[smart_mtu_max]=$(automtu_state_get "$state_file" max_mtu "$AUTOMTU_DEFAULT_MAX")
CONFIG[smart_mtu_step]=$(automtu_state_get "$state_file" step "$AUTOMTU_DEFAULT_STEP")
}

automtu_reset_learning() {
local config_name="$1" state_file enabled min_mtu max_mtu step
state_file=$(automtu_state_file "$config_name") || return 1
enabled=$(automtu_state_get "$state_file" enabled "false")
min_mtu=$(automtu_state_get "$state_file" min_mtu "$AUTOMTU_DEFAULT_MIN")
max_mtu=$(automtu_state_get "$state_file" max_mtu "$AUTOMTU_DEFAULT_MAX")
step=$(automtu_state_get "$state_file" step "$AUTOMTU_DEFAULT_STEP")
rm -f "$state_file"
automtu_save_settings "$config_name" "$enabled" "$min_mtu" "$max_mtu" "$step"
}

automtu_delete_state() {
local config_name="$1" state_file
state_file=$(automtu_state_file "$config_name") || return 1
rm -f "$state_file" "${state_file}.lock"
}

automtu_note() {
local mode="$1" level="$2" message="$3"
if [[ "$mode" == "manual" ]]; then
colorize "$level" "$message"
elif [[ "$level" == "green" || "$level" == "red" ]]; then
logger -t backhaul-auto-mtu "$message" 2>/dev/null
fi
}

automtu_service_stable() {
local service_name="$1" started_epoch now_epoch
systemctl is-active --quiet "$service_name" 2>/dev/null || return 1
started_epoch=$(systemctl show "$service_name" -p ActiveEnterTimestamp --value 2>/dev/null)
started_epoch=$(date -d "$started_epoch" +%s 2>/dev/null) || return 1
now_epoch=$(date +%s)
(( now_epoch - started_epoch >= AUTOMTU_MIN_SERVICE_UPTIME ))
}

automtu_system_load_ok() {
local load_one cpu_count
read -r load_one _ < /proc/loadavg || return 1
cpu_count=$(nproc 2>/dev/null || printf '1')
awk -v load_value="$load_one" -v cpus="$cpu_count" 'BEGIN { exit !(load_value <= cpus * 1.5) }'
}

automtu_service_bytes() {
local service_name="$1" rx tx
rx=$(systemctl show "$service_name" -p IPIngressBytes --value 2>/dev/null)
tx=$(systemctl show "$service_name" -p IPEgressBytes --value 2>/dev/null)
[[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]] || return 1
[[ "$rx" != "18446744073709551615" && "$tx" != "18446744073709551615" ]] || return 1
printf '%s\n' "$((rx + tx))"
}

automtu_service_is_busy() {
local service_name="$1" before after delta
before=$(automtu_service_bytes "$service_name") || return 2
sleep "$AUTOMTU_TRAFFIC_SAMPLE_SECONDS"
after=$(automtu_service_bytes "$service_name") || return 2
(( after >= before )) || return 2
delta=$(( (after - before) / AUTOMTU_TRAFFIC_SAMPLE_SECONDS ))
(( delta > AUTOMTU_MAX_RATE_BPS ))
}

automtu_iface_mtu() {
ip -o link show dev "$1" 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i=="mtu") { print $(i+1); exit } }'
}

automtu_ping_metrics() {
local iface="$1" host="$2" payload="$3" count="${4:-5}" out avg loss
[[ "$payload" =~ ^[0-9]+$ && "$payload" -ge 0 ]] || { echo "NA 100"; return 1; }
out=$(ping -I "$iface" -M "do" -s "$payload" -c "$count" -W 2 "$host" 2>/dev/null || true)
loss=$(awk 'match($0, /[0-9]+% packet loss/) { text=substr($0,RSTART,RLENGTH); sub(/%.*/,"",text); print text; exit }' <<< "$out")
avg=$(awk -F'= ' '/^(rtt|round-trip) / { split($2,a,"/"); print a[2]; exit }' <<< "$out")
[[ "$loss" =~ ^[0-9]+$ ]] || loss=100
[[ "$avg" =~ ^[0-9]+([.][0-9]+)?$ ]] || avg="NA"
printf '%s %s\n' "$avg" "$loss"
}

automtu_probe_score() {
local payload="$1" avg="$2" loss="$3"
if [[ "$avg" == "NA" || ! "$loss" =~ ^[0-9]+$ ]]; then
echo 0
return
fi
# The +25 dampens ordinary latency jitter so a larger packet is rewarded only
# when delivery remains at least as reliable.
awk -v p="$payload" -v a="$avg" -v l="$loss" 'BEGIN { printf "%.0f", p * (100-l) * 1000 / (a+25) }'
}

automtu_small_path_still_healthy() {
local base_avg="$1" base_loss="$2" candidate_avg="$3" candidate_loss="$4"
[[ "$base_avg" != "NA" && "$candidate_avg" != "NA" ]] || return 1
(( candidate_loss <= AUTOMTU_SMALL_MAX_LOSS && candidate_loss <= base_loss + 5 )) || return 1
awk -v before="$base_avg" -v after="$candidate_avg" 'BEGIN { exit !(after <= before * 1.30 + 5) }'
}

automtu_candidate_improves() {
local direction="$1" base_payload="$2" base_avg="$3" base_loss="$4" candidate_payload="$5" candidate_avg="$6" candidate_loss="$7"
local base_score candidate_score
[[ "$candidate_avg" != "NA" ]] || return 1
base_score=$(automtu_probe_score "$base_payload" "$base_avg" "$base_loss")
candidate_score=$(automtu_probe_score "$candidate_payload" "$candidate_avg" "$candidate_loss")
if [[ "$direction" == "up" ]]; then
(( candidate_loss <= base_loss + 1 )) || return 1
[[ "$base_avg" != "NA" ]] || return 1
awk -v before="$base_avg" -v after="$candidate_avg" 'BEGIN { exit !(after <= before * 1.20 + 3) }' || return 1
(( candidate_score * 1000 >= base_score * 1005 ))
else
if [[ "$base_avg" == "NA" ]]; then
(( candidate_loss <= AUTOMTU_SMALL_MAX_LOSS && candidate_score > 0 ))
return
fi
(( base_loss - candidate_loss >= 10 || (base_loss >= 80 && candidate_loss <= 20) )) || return 1
(( candidate_score * 100 >= base_score * 105 ))
fi
}

automtu_set_config_mtu() {
local config_path="$1" mtu="$2" tmp_file
[[ "$mtu" =~ ^[0-9]+$ ]] || return 1
tmp_file=$(mktemp "${config_path}.mtu.XXXXXX") || return 1
awk -v new_mtu="$mtu" '
FNR==1 { in_tun=0; changed=0 }
/^\[/ { in_tun=($0=="[tun]") }
in_tun && /^mtu[[:space:]]*=/ { print "mtu = " new_mtu; changed=1; next }
{ print }
END { if (!changed) exit 2 }
' "$config_path" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
chmod --reference="$config_path" "$tmp_file" 2>/dev/null || chmod 600 "$tmp_file"
mv -f "$tmp_file" "$config_path"
}

AUTOMTU_BACKUP_PATH=""
automtu_apply_candidate() {
local config_path="$1" service_name="$2" tun_name="$3" candidate="$4"
mkdir -p "$AUTOMTU_STATE_DIR" || return 1
AUTOMTU_BACKUP_PATH=$(mktemp "${AUTOMTU_STATE_DIR}/candidate.XXXXXX") || return 1
cp -p "$config_path" "$AUTOMTU_BACKUP_PATH" || { rm -f "$AUTOMTU_BACKUP_PATH"; return 1; }
if ! automtu_set_config_mtu "$config_path" "$candidate" || ! systemctl restart "$service_name" 2>/dev/null; then
cp -p "$AUTOMTU_BACKUP_PATH" "$config_path"
systemctl restart "$service_name" 2>/dev/null || true
return 1
fi
sleep "$AUTOMTU_SETTLE_SECONDS"
if ! systemctl is-active --quiet "$service_name" 2>/dev/null || ! tun_iface_exists "$tun_name"; then
cp -p "$AUTOMTU_BACKUP_PATH" "$config_path"
systemctl restart "$service_name" 2>/dev/null || true
return 1
fi
}

automtu_rollback_candidate() {
local config_path="$1" service_name="$2" backup_path="$3"
[[ -f "$backup_path" ]] || return 1
cp -p "$backup_path" "$config_path" || return 1
systemctl restart "$service_name" 2>/dev/null || return 1
sleep "$AUTOMTU_SETTLE_SECONDS"
systemctl is-active --quiet "$service_name" 2>/dev/null
}

automtu_record_skip() {
local state_file="$1" result="$2"
automtu_state_set "$state_file" last_check_epoch "$(date +%s)"
automtu_state_set "$state_file" last_skip "$result"
}

automtu_run_locked() {
local config_path="$1" mode="$2" config_name service_name state_file enabled min_mtu max_mtu step
local current iface_mtu tun_name remote_ip now cooldown dynamic_max small_avg small_loss probe_avg probe_loss
local good_streak bad_streak direction required candidate base_payload candidate_payload candidate_small_avg candidate_small_loss
local candidate_avg candidate_loss backup_path

config_name=$(basename "${config_path%.toml}")
service_name="backhaul-${config_name}.service"
state_file=$(automtu_state_file "$config_name") || return 1
enabled=$(automtu_state_get "$state_file" enabled "false")
[[ "$enabled" == "true" ]] || { automtu_note "$mode" yellow "Smart Auto-MTU is disabled for ${config_name}."; return 0; }
tunnel_is_tun "$config_path" && tunnel_is_ipx "$config_path" || { automtu_record_skip "$state_file" "not-tun-ipx"; return 0; }

min_mtu=$(automtu_state_get "$state_file" min_mtu "$AUTOMTU_DEFAULT_MIN")
max_mtu=$(automtu_state_get "$state_file" max_mtu "$AUTOMTU_DEFAULT_MAX")
step=$(automtu_state_get "$state_file" step "$AUTOMTU_DEFAULT_STEP")
automtu_validate_settings "$min_mtu" "$max_mtu" "$step" || { automtu_record_skip "$state_file" "invalid-settings"; return 1; }
current=$(toml_get "$config_path" tun mtu)
tun_name=$(toml_tun_name "$config_path")
remote_ip=$(toml_get "$config_path" tun remote_addr); remote_ip="${remote_ip%/*}"
[[ "$current" =~ ^[0-9]+$ && -n "$tun_name" && -n "$remote_ip" ]] || { automtu_record_skip "$state_file" "invalid-tun-config"; return 1; }
(( current >= min_mtu && current <= max_mtu )) || { automtu_record_skip "$state_file" "manual-mtu-outside-bounds"; return 0; }
service_should_run "$service_name" && automtu_service_stable "$service_name" || { automtu_record_skip "$state_file" "service-not-stable"; return 0; }
iface_mtu=$(automtu_iface_mtu "$tun_name")
[[ "$iface_mtu" == "$current" ]] || { automtu_record_skip "$state_file" "interface-config-mismatch"; return 0; }
if declare -F tunnel_health_ensure_fresh &>/dev/null; then
if ! tunnel_health_ensure_fresh "$config_path"; then
automtu_record_skip "$state_file" "health-collection-failed"
automtu_note "$mode" yellow "Auto-MTU skipped: tunnel health telemetry could not be collected safely."
return 0
fi
if ! tunnel_health_automtu_gate "$config_path"; then
automtu_record_skip "$state_file" "$HEALTH_GATE_REASON"
automtu_note "$mode" yellow "Auto-MTU skipped by Tunnel Health: ${HEALTH_GATE_REASON}."
return 0
fi
fi
automtu_system_load_ok || { automtu_record_skip "$state_file" "system-load-high"; return 0; }
local traffic_status
if automtu_service_is_busy "$service_name"; then traffic_status=0; else traffic_status=$?; fi
if (( traffic_status == 0 )); then
automtu_record_skip "$state_file" "traffic-high"
return 0
elif (( traffic_status == 2 )); then
automtu_record_skip "$state_file" "traffic-telemetry-unavailable"
return 0
fi

now=$(date +%s)
cooldown=$(automtu_state_get "$state_file" cooldown_until "0")
[[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=0
if [[ "$mode" != "manual" ]] && (( now < cooldown )); then
automtu_record_skip "$state_file" "cooldown"
return 0
fi

read -r small_avg small_loss <<< "$(automtu_ping_metrics "$tun_name" "$remote_ip" "$AUTOMTU_SMALL_PAYLOAD" 5)"
if [[ "$small_avg" == "NA" ]] || (( small_loss > AUTOMTU_SMALL_MAX_LOSS )); then
automtu_state_set "$state_file" good_streak 0
automtu_state_set "$state_file" bad_streak 0
automtu_record_skip "$state_file" "general-network-unhealthy"
automtu_note "$mode" yellow "Auto-MTU skipped: the small control probe is unhealthy, so the problem is not attributed to MTU."
return 0
fi

base_payload=$((current - 28))
(( base_payload >= AUTOMTU_SMALL_PAYLOAD )) || base_payload="$AUTOMTU_SMALL_PAYLOAD"
read -r probe_avg probe_loss <<< "$(automtu_ping_metrics "$tun_name" "$remote_ip" "$base_payload" 5)"
good_streak=$(automtu_state_get "$state_file" good_streak "0"); [[ "$good_streak" =~ ^[0-9]+$ ]] || good_streak=0
bad_streak=$(automtu_state_get "$state_file" bad_streak "0"); [[ "$bad_streak" =~ ^[0-9]+$ ]] || bad_streak=0
direction=""
if [[ "$probe_avg" == "NA" ]] || (( probe_loss >= AUTOMTU_LARGE_BAD_LOSS )); then
bad_streak=$((bad_streak + 1)); good_streak=0; direction="down"
required="$AUTOMTU_BAD_STREAK_REQUIRED"
else
if (( probe_loss <= AUTOMTU_LARGE_GOOD_LOSS )); then
good_streak=$((good_streak + 1)); bad_streak=0; direction="up"
required="$AUTOMTU_GOOD_STREAK_REQUIRED"
else
good_streak=0; bad_streak=0
fi
fi
automtu_state_set "$state_file" good_streak "$good_streak"
automtu_state_set "$state_file" bad_streak "$bad_streak"
automtu_state_set "$state_file" last_baseline "mtu:${current},small:${small_avg}/${small_loss},large:${probe_avg}/${probe_loss}"
automtu_state_set "$state_file" last_check_epoch "$now"

if [[ -z "$direction" ]]; then
automtu_state_set "$state_file" last_result "inconclusive-no-change"
return 0
fi
[[ "$mode" == "manual" ]] && required=1
if [[ "$direction" == "up" && "$good_streak" -lt "$required" ]] || [[ "$direction" == "down" && "$bad_streak" -lt "$required" ]]; then
automtu_state_set "$state_file" last_result "collecting-${direction}-evidence"
return 0
fi

dynamic_max=$(automtu_state_get "$state_file" dynamic_max "$max_mtu")
[[ "$dynamic_max" =~ ^[0-9]+$ ]] || dynamic_max="$max_mtu"
(( dynamic_max > max_mtu )) && dynamic_max="$max_mtu"
if [[ "$direction" == "up" ]]; then
candidate=$((current + step)); (( candidate > dynamic_max )) && candidate="$dynamic_max"
else
candidate=$((current - step)); (( candidate < min_mtu )) && candidate="$min_mtu"
fi
if (( candidate == current )); then
automtu_state_set "$state_file" last_result "at-${direction}-bound"
return 0
fi

automtu_note "$mode" cyan "Testing MTU ${candidate} against current MTU ${current}..."
AUTOMTU_BACKUP_PATH=""
if ! automtu_apply_candidate "$config_path" "$service_name" "$tun_name" "$candidate"; then
backup_path="$AUTOMTU_BACKUP_PATH"
local apply_result="candidate-apply-failed-no-change"
if [[ -n "$backup_path" && -f "$backup_path" ]]; then
if [[ "$(toml_get "$config_path" tun mtu)" == "$current" ]] && systemctl is-active --quiet "$service_name" 2>/dev/null; then
rm -f "$backup_path"
automtu_state_unset "$state_file" recovery_backup || true
apply_result="candidate-apply-failed-rolled-back"
else
automtu_state_set "$state_file" recovery_backup "$backup_path"
apply_result="candidate-apply-failed-recovery-required"
fi
fi
automtu_state_set "$state_file" cooldown_until "$((now + AUTOMTU_REJECT_COOLDOWN))"
automtu_state_set "$state_file" last_result "$apply_result"
if [[ "$apply_result" == "candidate-apply-failed-recovery-required" ]]; then
automtu_note "$mode" red "Candidate MTU could not start cleanly; recovery backup retained at ${backup_path}."
else
automtu_note "$mode" red "Candidate MTU could not start cleanly; no candidate MTU was left active."
fi
return 1
fi
backup_path="$AUTOMTU_BACKUP_PATH"
candidate_payload=$((candidate - 28)); (( candidate_payload >= AUTOMTU_SMALL_PAYLOAD )) || candidate_payload="$AUTOMTU_SMALL_PAYLOAD"
read -r candidate_small_avg candidate_small_loss <<< "$(automtu_ping_metrics "$tun_name" "$remote_ip" "$AUTOMTU_SMALL_PAYLOAD" 5)"
read -r candidate_avg candidate_loss <<< "$(automtu_ping_metrics "$tun_name" "$remote_ip" "$candidate_payload" 5)"

if automtu_small_path_still_healthy "$small_avg" "$small_loss" "$candidate_small_avg" "$candidate_small_loss" &&
automtu_candidate_improves "$direction" "$base_payload" "$probe_avg" "$probe_loss" "$candidate_payload" "$candidate_avg" "$candidate_loss"; then
rm -f "$backup_path"
automtu_state_unset "$state_file" recovery_backup || true
automtu_state_set "$state_file" good_streak 0
automtu_state_set "$state_file" bad_streak 0
automtu_state_set "$state_file" last_change_epoch "$now"
automtu_state_set "$state_file" cooldown_until "$((now + AUTOMTU_CHANGE_COOLDOWN))"
automtu_state_set "$state_file" best_mtu "$candidate"
automtu_state_set "$state_file" last_result "accepted-${direction}-${current}-to-${candidate}"
automtu_note "$mode" green "Smart Auto-MTU accepted ${candidate}: the A/B probe improved without harming the control path."
return 0
fi

if automtu_rollback_candidate "$config_path" "$service_name" "$backup_path"; then
automtu_note "$mode" yellow "MTU ${candidate} did not improve the A/B result; rolled back to ${current}."
rm -f "$backup_path"
automtu_state_unset "$state_file" recovery_backup || true
else
automtu_note "$mode" red "MTU candidate was rejected and rollback needs manual verification for ${service_name}."
automtu_state_set "$state_file" recovery_backup "$backup_path"
fi
if [[ "$direction" == "up" ]]; then
# Do not keep trying almost-identical larger values after a failed A/B test.
# A manual learning reset reopens upward exploration after the path changes.
automtu_state_set "$state_file" dynamic_max "$current"
fi
automtu_state_set "$state_file" good_streak 0
automtu_state_set "$state_file" bad_streak 0
automtu_state_set "$state_file" cooldown_until "$((now + AUTOMTU_REJECT_COOLDOWN))"
automtu_state_set "$state_file" last_result "rejected-${direction}-${candidate}-rolled-back"
}

automtu_run() {
local config_path="$1" mode="${2:-watchdog}" config_name state_file lock_fd
[[ -f "$config_path" ]] || return 1
config_name=$(basename "${config_path%.toml}")
state_file=$(automtu_state_file "$config_name") || return 1
mkdir -p "$AUTOMTU_STATE_DIR" || return 1
if command -v flock &>/dev/null; then
exec {lock_fd}>"${state_file}.lock"
flock -n "$lock_fd" || return 0
fi
local result
if automtu_run_locked "$config_path" "$mode"; then
result=0
else
result=$?
fi
if [[ -n "${lock_fd:-}" ]]; then
flock -u "$lock_fd" 2>/dev/null || true
exec {lock_fd}>&-
fi
return "$result"
}

automtu_status_text() {
local config_name="$1" current_mtu="$2" state_file enabled min_mtu max_mtu step last_result last_skip last_change recovery_backup
state_file=$(automtu_state_file "$config_name") || return 1
enabled=$(automtu_state_get "$state_file" enabled "false")
min_mtu=$(automtu_state_get "$state_file" min_mtu "$AUTOMTU_DEFAULT_MIN")
max_mtu=$(automtu_state_get "$state_file" max_mtu "$AUTOMTU_DEFAULT_MAX")
step=$(automtu_state_get "$state_file" step "$AUTOMTU_DEFAULT_STEP")
last_result=$(automtu_state_get "$state_file" last_result "never-run")
last_skip=$(automtu_state_get "$state_file" last_skip "none")
last_change=$(automtu_state_get "$state_file" last_change_epoch "never")
recovery_backup=$(automtu_state_get "$state_file" recovery_backup "none")
printf '%s | current=%s range=%s-%s step=%s | %s | skip=%s | last-change=%s' "$enabled" "$current_mtu" "$min_mtu" "$max_mtu" "$step" "$last_result" "$last_skip" "$last_change"
[[ "$recovery_backup" == "none" ]] || printf ' | RECOVERY-BACKUP=%s' "$recovery_backup"
printf '\n'
}

#!/usr/bin/env bash
# shellcheck disable=SC2154 # config_dir is provided by tunnel-manager.sh before sourcing.
# Conservative, reversible network tuning for tunnel-manager.
# This file is sourced by tunnel-manager.sh after lib/common.sh.

NETTUNE_SYSCTL_CONF="/etc/sysctl.d/99-tunnel-vm.conf"
NETTUNE_BBR_MODULE_CONF="/etc/modules-load.d/tunnel-vm-bbr.conf"
NETTUNE_SYSTEMD_LIMIT_CONF="/etc/systemd/system.conf.d/99-tunnel-vm-nofile.conf"
NETTUNE_LIMITS_CONF="/etc/security/limits.conf"
NETTUNE_MEMINFO="/proc/meminfo"
NETTUNE_CONNTRACK_PATH="/proc/sys/net/netfilter/nf_conntrack_max"
NETTUNE_LIMITS_TAG="tunnel-manager-network-tune"
NETTUNE_STATE_DIR="${config_dir}/.network-tune-state"
NETTUNE_VALUES_FILE="${NETTUNE_STATE_DIR}/sysctl-values.tsv"
NETTUNE_LAST_BACKUP_FILE="${config_dir}/.network-tune-last-backup"

core_optimize_is_applied() {
[[ -f "$NETTUNE_SYSCTL_CONF" ]]
}

nettune_snapshot_file() {
local path="$1" name="$2"
if [[ -e "$path" ]]; then
printf '1\n' > "${NETTUNE_STATE_DIR}/${name}.exists"
cp -a -- "$path" "${NETTUNE_STATE_DIR}/${name}.backup"
else
printf '0\n' > "${NETTUNE_STATE_DIR}/${name}.exists"
fi
}

nettune_restore_file() {
local path="$1" name="$2" existed
existed=$(cat "${NETTUNE_STATE_DIR}/${name}.exists" 2>/dev/null || printf '0')
if [[ "$existed" == "1" && -e "${NETTUNE_STATE_DIR}/${name}.backup" ]]; then
mkdir -p "$(dirname "$path")"
cp -a -- "${NETTUNE_STATE_DIR}/${name}.backup" "$path"
else
rm -f -- "$path"
fi
}

nettune_keys() {
cat <<'EOF'
net.core.rmem_max
net.core.wmem_max
net.core.rmem_default
net.core.wmem_default
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.core.netdev_max_backlog
net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.ipv4.ip_local_port_range
net.ipv4.ip_local_reserved_ports
net.ipv4.tcp_fin_timeout
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.netfilter.nf_conntrack_max
net.core.default_qdisc
net.ipv4.tcp_congestion_control
EOF
}

# Capture the baseline only once. Re-applying optimization must never replace
# the values needed for a real rollback with already-tuned values.
nettune_capture_baseline() {
[[ -f "$NETTUNE_VALUES_FILE" ]] && return 0

mkdir -p "$NETTUNE_STATE_DIR"
chmod 700 "$NETTUNE_STATE_DIR"
nettune_snapshot_file "$NETTUNE_SYSCTL_CONF" sysctl-conf || return 1
nettune_snapshot_file "$NETTUNE_BBR_MODULE_CONF" bbr-module || return 1
nettune_snapshot_file "$NETTUNE_SYSTEMD_LIMIT_CONF" systemd-limit || return 1
nettune_snapshot_file "$NETTUNE_LIMITS_CONF" limits-conf || return 1

: > "$NETTUNE_VALUES_FILE"
local key value
while IFS= read -r key; do
[[ -n "$key" ]] || continue
if value=$(sysctl -n "$key" 2>/dev/null); then
printf '%s\t%s\n' "$key" "$value" >> "$NETTUNE_VALUES_FILE"
fi
done < <(nettune_keys)
chmod 600 "$NETTUNE_VALUES_FILE"
printf '%s\n' "$NETTUNE_STATE_DIR" > "$NETTUNE_LAST_BACKUP_FILE"
}

nettune_max_value() {
local key="$1" proposed="$2" current
current=$(sysctl -n "$key" 2>/dev/null || printf '0')
if [[ "$current" =~ ^[0-9]+$ ]] && (( current > proposed )); then
printf '%s' "$current"
else
printf '%s' "$proposed"
fi
}

nettune_merge_reserved_ports() {
local current listening
current=$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null || true)
listening=$( { ss -Htln 2>/dev/null; ss -Huln 2>/dev/null; } |
awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | paste -sd, - )

printf '%s\n%s\n' "$current" "$listening" |
tr ',' '\n' | awk 'NF && $0 ~ /^[0-9]+(-[0-9]+)?$/ { if (!seen[$0]++) print $0 }' |
sort -V | paste -sd, -
}

nettune_remove_legacy_global_limits() {
# Older releases changed limits for every login and every systemd service.
# Panel units already carry their own LimitNOFILE, so these global mutations
# are unnecessary and are removed while their exact old files remain saved.
if grep -q "^# ${NETTUNE_LIMITS_TAG}$" "$NETTUNE_LIMITS_CONF" 2>/dev/null; then
sed -i "/^# ${NETTUNE_LIMITS_TAG}$/,+4d" "$NETTUNE_LIMITS_CONF"
fi
if [[ -f "$NETTUNE_SYSTEMD_LIMIT_CONF" ]]; then
rm -f -- "$NETTUNE_SYSTEMD_LIMIT_CONF"
systemctl daemon-reexec 2>/dev/null || true
fi
}

core_optimize_apply() {
colorize cyan "--- Optimize Network (safe and reversible) ---" bold
echo ""

local bbr_ok=0 conntrack_ok=0
if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
modprobe tcp_bbr 2>/dev/null || true
fi
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
bbr_ok=1
fi
[[ -e "$NETTUNE_CONNTRACK_PATH" ]] && conntrack_ok=1

if ! nettune_capture_baseline; then
colorize red "Could not save the pre-optimization state. Nothing was changed."
return 1
fi
nettune_remove_legacy_global_limits

local memory_kb buffer_max tcp_buffer conntrack_max backlog
memory_kb=$(awk '/^MemTotal:/ {print $2; exit}' "$NETTUNE_MEMINFO" 2>/dev/null)
memory_kb=${memory_kb:-2097152}
if (( memory_kb < 2097152 )); then
buffer_max=16777216; tcp_buffer=8388608; conntrack_max=131072; backlog=10000
elif (( memory_kb < 8388608 )); then
buffer_max=33554432; tcp_buffer=16777216; conntrack_max=262144; backlog=20000
else
buffer_max=67108864; tcp_buffer=33554432; conntrack_max=524288; backlog=30000
fi

# Do not reduce a deliberately higher value already chosen by the admin.
buffer_max=$(nettune_max_value net.core.rmem_max "$buffer_max")
local wmem_max rmem_default wmem_default somaxconn syn_backlog
wmem_max=$(nettune_max_value net.core.wmem_max "$buffer_max")
rmem_default=$(nettune_max_value net.core.rmem_default 1048576)
wmem_default=$(nettune_max_value net.core.wmem_default 1048576)
backlog=$(nettune_max_value net.core.netdev_max_backlog "$backlog")
somaxconn=$(nettune_max_value net.core.somaxconn 65535)
syn_backlog=$(nettune_max_value net.ipv4.tcp_max_syn_backlog 8192)
if [[ "$conntrack_ok" == "1" ]]; then
conntrack_max=$(nettune_max_value net.netfilter.nf_conntrack_max "$conntrack_max")
fi

local current_tcp current_tcp_min current_tcp_default current_tcp_max
local tcp_rmem_min=4096 tcp_rmem_default=87380 tcp_rmem_max="$tcp_buffer"
local tcp_wmem_min=4096 tcp_wmem_default=65536 tcp_wmem_max="$tcp_buffer"
current_tcp=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true)
read -r current_tcp_min current_tcp_default current_tcp_max <<< "$current_tcp"
[[ "$current_tcp_min" =~ ^[0-9]+$ ]] && (( current_tcp_min > tcp_rmem_min )) && tcp_rmem_min="$current_tcp_min"
[[ "$current_tcp_default" =~ ^[0-9]+$ ]] && (( current_tcp_default > tcp_rmem_default )) && tcp_rmem_default="$current_tcp_default"
[[ "$current_tcp_max" =~ ^[0-9]+$ ]] && (( current_tcp_max > tcp_rmem_max )) && tcp_rmem_max="$current_tcp_max"
current_tcp=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true)
read -r current_tcp_min current_tcp_default current_tcp_max <<< "$current_tcp"
[[ "$current_tcp_min" =~ ^[0-9]+$ ]] && (( current_tcp_min > tcp_wmem_min )) && tcp_wmem_min="$current_tcp_min"
[[ "$current_tcp_default" =~ ^[0-9]+$ ]] && (( current_tcp_default > tcp_wmem_default )) && tcp_wmem_default="$current_tcp_default"
[[ "$current_tcp_max" =~ ^[0-9]+$ ]] && (( current_tcp_max > tcp_wmem_max )) && tcp_wmem_max="$current_tcp_max"

local current_range range_low=10000 range_high=65535 current_low current_high
current_range=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || true)
read -r current_low current_high <<< "$current_range"
[[ "$current_low" =~ ^[0-9]+$ ]] && (( current_low >= 1024 && current_low < range_low )) && range_low="$current_low"
[[ "$current_high" =~ ^[0-9]+$ ]] && (( current_high > range_high && current_high <= 65535 )) && range_high="$current_high"

local reserved_ports temp_conf
reserved_ports=$(nettune_merge_reserved_ports)
mkdir -p "$(dirname "$NETTUNE_SYSCTL_CONF")"
if ! temp_conf=$(mktemp "${NETTUNE_SYSCTL_CONF}.XXXXXX"); then
colorize red "Could not create the temporary tuning file; restoring the saved state."
core_optimize_rollback
return 1
fi
cat > "$temp_conf" <<EOF
# Managed by tunnel-manager. Remove through Optimize > Rollback.
# Values are sized from installed RAM and never reduce larger admin settings.
net.core.rmem_max = ${buffer_max}
net.core.wmem_max = ${wmem_max}
net.core.rmem_default = ${rmem_default}
net.core.wmem_default = ${wmem_default}
net.ipv4.tcp_rmem = ${tcp_rmem_min} ${tcp_rmem_default} ${tcp_rmem_max}
net.ipv4.tcp_wmem = ${tcp_wmem_min} ${tcp_wmem_default} ${tcp_wmem_max}
net.core.netdev_max_backlog = ${backlog}
net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.ipv4.ip_local_port_range = ${range_low} ${range_high}
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF
[[ -n "$reserved_ports" ]] && printf 'net.ipv4.ip_local_reserved_ports = %s\n' "$reserved_ports" >> "$temp_conf"
[[ "$conntrack_ok" == "1" ]] && printf 'net.netfilter.nf_conntrack_max = %s\n' "$conntrack_max" >> "$temp_conf"
if [[ "$bbr_ok" == "1" ]]; then
printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >> "$temp_conf"
mkdir -p "$(dirname "$NETTUNE_BBR_MODULE_CONF")"
printf 'tcp_bbr\n' > "$NETTUNE_BBR_MODULE_CONF"
else
rm -f -- "$NETTUNE_BBR_MODULE_CONF"
fi
chmod 644 "$temp_conf"
if ! mv -f -- "$temp_conf" "$NETTUNE_SYSCTL_CONF"; then
rm -f -- "$temp_conf"
colorize red "Could not activate the tuning file; restoring the saved state."
core_optimize_rollback
return 1
fi

if ! sysctl -e -p "$NETTUNE_SYSCTL_CONF" >/dev/null; then
colorize red "Kernel rejected one or more tuning values; restoring the saved state."
core_optimize_rollback
return 1
fi

colorize green "Network tuning applied. Original values are saved in: $NETTUNE_STATE_DIR"
echo "RAM profile:          $((memory_kb / 1024)) MB"
echo "Congestion control:  $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
echo "Default qdisc:       $(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
echo "Socket buffers:      rmem=${buffer_max}, wmem=${wmem_max}"
echo "somaxconn:           $(sysctl -n net.core.somaxconn 2>/dev/null || echo n/a)"
[[ "$conntrack_ok" == "1" ]] && echo "conntrack max:       $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo n/a)"
[[ -n "$reserved_ports" ]] && echo "Reserved ports:      $reserved_ports"
echo ""
colorize yellow "Re-run Optimize after adding listeners so their ports are merged into the reservation list."
colorize yellow "No active qdisc, global PAM limit, or global systemd limit is modified."
}

core_optimize_rollback() {
if [[ ! -f "$NETTUNE_VALUES_FILE" ]]; then
# Compatibility cleanup for installations optimized by an older release.
if core_optimize_is_applied || [[ -f "$NETTUNE_BBR_MODULE_CONF" || -f "$NETTUNE_SYSTEMD_LIMIT_CONF" ]]; then
rm -f -- "$NETTUNE_SYSCTL_CONF" "$NETTUNE_BBR_MODULE_CONF" "$NETTUNE_SYSTEMD_LIMIT_CONF"
sed -i "/^# ${NETTUNE_LIMITS_TAG}$/,+4d" "$NETTUNE_LIMITS_CONF" 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true
systemctl daemon-reexec 2>/dev/null || true
colorize yellow "Legacy optimization files were removed. An exact old runtime snapshot was not available."
else
colorize yellow "Nothing to roll back -- optimization was never applied."
fi
return 0
fi

nettune_restore_file "$NETTUNE_SYSCTL_CONF" sysctl-conf
nettune_restore_file "$NETTUNE_BBR_MODULE_CONF" bbr-module
nettune_restore_file "$NETTUNE_SYSTEMD_LIMIT_CONF" systemd-limit
nettune_restore_file "$NETTUNE_LIMITS_CONF" limits-conf
sysctl --system >/dev/null 2>&1 || true

local key value restore_failed=0
while IFS=$'\t' read -r key value; do
[[ -n "$key" ]] || continue
if ! sysctl -w "${key}=${value}" >/dev/null 2>&1; then
restore_failed=1
colorize yellow "Could not restore runtime value: $key"
fi
done < "$NETTUNE_VALUES_FILE"
systemctl daemon-reexec 2>/dev/null || true

local archive_dir
archive_dir="${config_dir}/.backups/network-tune.rollback.$(date +%Y%m%d%H%M%S)"
mkdir -p "$(dirname "$archive_dir")"
if [[ "$restore_failed" == "0" ]]; then
mv -- "$NETTUNE_STATE_DIR" "$archive_dir"
printf '%s\n' "$archive_dir" > "$NETTUNE_LAST_BACKUP_FILE"
colorize green "Optimization rolled back to the exact saved values. Snapshot archived at: $archive_dir"
else
colorize yellow "Rollback was partial. State was kept at $NETTUNE_STATE_DIR so it can be retried."
return 1
fi
}

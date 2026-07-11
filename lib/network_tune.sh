#!/usr/bin/env bash
# Kernel/network tuning menu-driven counterpart of the standalone
# https://github.com/dr-hoseyn/vm-network-tuner script: buffers, BBR+fq,
# conntrack, and ephemeral-port reservation for whatever this panel's
# engines currently have listening. Sourced by tunnel-manager.sh right after
# lib/common.sh (needs colorize/press_key and the config_dir global, nothing
# engine-specific).
NETTUNE_SYSCTL_CONF="/etc/sysctl.d/99-tunnel-vm.conf"
NETTUNE_BBR_MODULE_CONF="/etc/modules-load.d/tunnel-vm-bbr.conf"
NETTUNE_SYSTEMD_LIMIT_CONF="/etc/systemd/system.conf.d/99-tunnel-vm-nofile.conf"
NETTUNE_LIMITS_TAG="tunnel-manager-network-tune"
NETTUNE_LAST_BACKUP_FILE="${config_dir}/.network-tune-last-backup"

core_optimize_is_applied() {
[[ -f "$NETTUNE_SYSCTL_CONF" ]]
}

# Snapshot of everything this touches, kept next to the panel's other backups
# (config_dir/.backups) rather than loose files under /root.
core_optimize_backup() {
local ts backup_dir
ts=$(date +%Y%m%d%H%M%S)
backup_dir="${config_dir}/.backups/network-tune.${ts}"
mkdir -p "$backup_dir"
sysctl -a > "${backup_dir}/sysctl-backup.txt" 2>/dev/null
cp -n /etc/security/limits.conf "${backup_dir}/limits.conf.bak" 2>/dev/null
echo "$backup_dir" > "$NETTUNE_LAST_BACKUP_FILE"
echo "$backup_dir"
}

core_optimize_apply() {
colorize cyan "━━━ Optimize Network (BBR, buffers, conntrack, port reservation) ━━━" bold
echo ""

local backup_dir
backup_dir=$(core_optimize_backup)
colorize green "Backup saved to ${backup_dir}"

local bbr_ok=0
if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
modprobe tcp_bbr 2>/dev/null
fi
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
bbr_ok=1
colorize green "BBR is available"
mkdir -p /etc/modules-load.d
grep -qs '^tcp_bbr$' "$NETTUNE_BBR_MODULE_CONF" 2>/dev/null || echo tcp_bbr > "$NETTUNE_BBR_MODULE_CONF"
else
colorize yellow "BBR not available in this kernel/container -- applying buffer tuning only"
fi

local conntrack_ok=0
[[ -f /proc/sys/net/netfilter/nf_conntrack_max ]] || modprobe nf_conntrack 2>/dev/null
if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
conntrack_ok=1
[[ -w /sys/module/nf_conntrack/parameters/hashsize ]] && echo 65536 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
colorize green "conntrack is available"
else
colorize yellow "conntrack not available in this kernel/container -- skipping"
fi

# Reserve ports already in LISTEN state instead of narrowing the ephemeral
# range below -- this panel's engines are built for many concurrent
# connections, so the range itself needs to stay wide.
local reserved_ports
reserved_ports=$( { ss -Htln 2>/dev/null; ss -Huln 2>/dev/null; } | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | paste -sd, - )
if [[ -n "$reserved_ports" ]]; then
colorize green "Reserving currently-listening ports from the ephemeral range: $reserved_ports"
else
colorize yellow "No listening ports detected to reserve"
fi

cat > "$NETTUNE_SYSCTL_CONF" << 'EOF'
# --- Network buffers ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 30000
# --- Connection capacity (wide on purpose -- see ip_local_reserved_ports
# below for how each tunnel's own bind port is kept safe) ---
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
# --- Misc improvements ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_no_metrics_save = 1
# --- Dead-peer detection for long-lived tunnel connections ---
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF

[[ -n "$reserved_ports" ]] && echo "net.ipv4.ip_local_reserved_ports = $reserved_ports" >> "$NETTUNE_SYSCTL_CONF"

if [[ "$conntrack_ok" == "1" ]]; then
cat >> "$NETTUNE_SYSCTL_CONF" << 'EOF'
# --- Connection tracking ---
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
EOF
fi

if [[ "$bbr_ok" == "1" ]]; then
cat >> "$NETTUNE_SYSCTL_CONF" << 'EOF'
# --- BBR ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
fi

# -e: ignore keys this kernel/namespace doesn't expose (common in
# OpenVZ/LXC guests) instead of aborting the whole apply on the first miss.
sysctl -e -p "$NETTUNE_SYSCTL_CONF" > /dev/null
colorize green "Sysctl settings applied"

if [[ "$bbr_ok" == "1" ]]; then
echo "Applying fq qdisc to active interfaces (default_qdisc alone only affects newly-created ones):"
local iface
for iface in $(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$'); do
if tc qdisc replace dev "$iface" root fq 2>/dev/null; then
echo "  $iface -> fq"
else
echo "  $iface -> could not set fq (non-fatal)"
fi
done
fi

if ! grep -q "$NETTUNE_LIMITS_TAG" /etc/security/limits.conf 2>/dev/null; then
cat >> /etc/security/limits.conf << EOF
# $NETTUNE_LIMITS_TAG
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
fi
colorize green "limits.conf updated"

# Every engine in this panel already sets LimitNOFILE=1048576 on its own
# systemd unit, so this drop-in is for OTHER services on the box (sshd, nginx,
# cron, ...) -- limits.conf itself is only read by PAM login sessions.
mkdir -p /etc/systemd/system.conf.d
cat > "$NETTUNE_SYSTEMD_LIMIT_CONF" << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
systemctl daemon-reexec 2>/dev/null
colorize green "systemd DefaultLimitNOFILE raised for non-panel services"

echo ""
colorize blue "── Verification ──" bold
echo "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
echo "Qdisc:               $(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
echo "somaxconn:           $(sysctl -n net.core.somaxconn 2>/dev/null)"
[[ "$conntrack_ok" == "1" ]] && echo "conntrack max:       $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo n/a)"
[[ -n "$reserved_ports" ]] && echo "Reserved ports:      $reserved_ports"
echo ""
colorize yellow "Note: so_rcvbuf/so_sndbuf in a tunnel's config are capped by rmem_max/wmem_max (now 64MB) -- values like so_rcvbuf=4194304 will now actually take effect instead of being silently clamped."
colorize yellow "Note: if a TUN tunnel uses ipx encapsulation (gre/ipip/icmp/...), set that tunnel's own 'mss' explicitly (1200-1360) -- tcp_mtu_probing alone doesn't fully cover the encapsulation overhead."
colorize yellow "Reserved-port detection above is a snapshot -- re-run this after configuring a new tunnel/port."
}

core_optimize_rollback() {
if ! core_optimize_is_applied && [[ ! -f "$NETTUNE_BBR_MODULE_CONF" ]]; then
colorize yellow "Nothing to roll back -- optimization was never applied."
return 0
fi
rm -f "$NETTUNE_SYSCTL_CONF" "$NETTUNE_BBR_MODULE_CONF" "$NETTUNE_SYSTEMD_LIMIT_CONF"
sed -i "/# $NETTUNE_LIMITS_TAG/,+4d" /etc/security/limits.conf 2>/dev/null
systemctl daemon-reexec 2>/dev/null
sysctl --system > /dev/null 2>&1
local last_backup
last_backup=$(cat "$NETTUNE_LAST_BACKUP_FILE" 2>/dev/null)
colorize green "Rolled back. Pre-change values are still in: ${last_backup:-${config_dir}/.backups/}"
}

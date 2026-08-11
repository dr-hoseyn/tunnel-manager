#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals configure the sourced health module.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

config_dir="${TEST_ROOT}/config"
service_dir="${TEST_ROOT}/systemd"
HEALTH_HISTORY_LIMIT=3
HEALTH_SAMPLE_MAX_AGE=600
mkdir -p "$config_dir" "$service_dir"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/tunnel_health.sh
source "${ROOT_DIR}/lib/tunnel_health.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }

classification_of() {
health_classify "$@" | cut -d'|' -f1
}

test_classifier_priorities() {
assert_eq "$(classification_of false false false NA NA 100 NA NA 100 NA 100 NA NA NA NA NA NA NA NA NA)" service-disabled
assert_eq "$(classification_of true false false NA NA 100 NA NA 100 NA 100 NA NA NA NA NA NA NA NA NA)" service-failure
assert_eq "$(classification_of true true false NA NA 100 NA NA 100 NA 100 NA NA NA NA NA NA NA NA NA)" tunnel-interface-down
assert_eq "$(classification_of true true true 1 20 0 1 20 0 20 0 0 0 0 0 10 20 30 10 20)" service-restarting
assert_eq "$(classification_of true true true 0 NA 100 NA NA 100 NA 100 0 20 1 0 10 20 30 10 20)" physical-interface-drops
assert_eq "$(classification_of true true true 0 NA 100 NA NA 100 NA 100 0 0 0 0 95 120 30 10 20)" cpu-saturation
assert_eq "$(classification_of true true true 0 20 0 1 20 0 20 0 0 0 0 0 10 20 96 10 20)" memory-pressure
assert_eq "$(classification_of true true true 0 20 0 1 20 0 20 0 0 0 0 0 10 20 30 95 20)" conntrack-pressure
assert_eq "$(classification_of true true true 0 20 0 1 20 0 20 0 20 0 0 0 10 20 30 10 20)" tunnel-interface-drops
assert_eq "$(classification_of true true true 0 NA 100 NA NA 100 20 0 0 0 0 0 10 20 30 10 20)" tunnel-path-failure
assert_eq "$(classification_of true true true 0 NA 100 NA NA 100 NA 100 0 0 0 0 10 20 30 10 20)" peer-or-underlay-unreachable
assert_eq "$(classification_of true true true 0 80 0 10 80 0 20 0 0 0 0 20 10 20 30 10 20)" network-congestion
assert_eq "$(classification_of true true true 0 20 0 1 NA 100 20 0 0 0 0 0 10 20 30 10 20)" mtu-suspected
assert_eq "$(classification_of true true true 0 20 0 1 21 0 20 0 0 0 0 0 10 20 30 10 20)" healthy
}

CONFIG_PATH="${config_dir}/iran1234.toml"
cat > "$CONFIG_PATH" <<'EOF'
[transport]
type = "tun"

[tun]
encapsulation = "ipx"
name = "health0"
local_addr = "10.10.10.1/24"
remote_addr = "10.10.10.2/24"
mtu = 1320

[ipx]
mode = "server"
profile = "tcp"
listen_ip = "192.0.2.1"
dst_ip = "192.0.2.2"
interface = "eth0"
EOF

SAMPLE_INDEX=1
PING_SCENARIO="mtu"
systemctl() {
case "${1:-}" in
is-enabled|is-active) return 0 ;;
show) return 0 ;;
*) return 0 ;;
esac
}
logger() { :; }
health_iface_exists() { return 0; }
health_route_iface() { printf 'eth0\n'; }
detect_default_interface() { printf 'eth0\n'; }
health_iface_snapshot() {
if [[ "$1" == "health0" ]]; then
printf '%s %s 100 100 0 0 0 0\n' "$((100000 + SAMPLE_INDEX * 1000))" "$((200000 + SAMPLE_INDEX * 1000))"
else
local drops=0
[[ "$PING_SCENARIO" == "physical_bad" ]] && drops=20
printf '%s %s 100 100 0 0 %s 0\n' "$((300000 + SAMPLE_INDEX * 1000))" "$((400000 + SAMPLE_INDEX * 1000))" "$drops"
fi
}
health_qdisc_drops() { printf '0\n'; }
health_service_value() {
case "$2" in
CPUUsageNSec) printf '%s\n' "$((SAMPLE_INDEX * 1000000000))" ;;
MemoryCurrent) printf '104857600\n' ;;
IPIngressBytes) printf '%s\n' "$((SAMPLE_INDEX * 100000))" ;;
IPEgressBytes) printf '%s\n' "$((SAMPLE_INDEX * 200000))" ;;
NRestarts) printf '0\n' ;;
*) printf 'NA\n' ;;
esac
}
health_conntrack_pct() { printf '10\n'; }
health_system_load_pct() { printf '20\n'; }
health_memory_pct() { printf '30\n'; }
health_ping_metrics() {
local iface="$1" payload="$3"
if [[ "$iface" == "eth0" ]]; then
printf '20 0 1\n'
elif [[ "$PING_SCENARIO" == "physical_bad" ]]; then
printf 'NA 100 NA\n'
elif [[ "$PING_SCENARIO" == "mtu" && "$payload" != "$HEALTH_SMALL_PAYLOAD" ]]; then
printf 'NA 100 NA\n'
else
printf '20 0 1\n'
fi
}

test_collection_history_and_gate() {
local latest history result
latest=$(health_latest_file iran1234)
history=$(health_history_file iran1234)
result=$(health_collect_locked "$CONFIG_PATH" manual)
assert_eq "${result%%|*}" mtu-suspected
assert_eq "$(health_state_get "$latest" classification none)" mtu-suspected
tunnel_health_automtu_gate "$CONFIG_PATH" || fail "MTU-specific diagnosis blocked Auto-MTU"

SAMPLE_INDEX=2
PING_SCENARIO=healthy
health_collect_locked "$CONFIG_PATH" watchdog
assert_eq "$(health_state_get "$latest" classification none)" healthy

SAMPLE_INDEX=3
PING_SCENARIO=physical_bad
health_collect_locked "$CONFIG_PATH" watchdog
assert_eq "$(health_state_get "$latest" classification none)" physical-interface-drops
if tunnel_health_automtu_gate "$CONFIG_PATH"; then fail "physical-link problem allowed Auto-MTU"; fi
assert_eq "$HEALTH_GATE_REASON" health-class-physical-interface-drops

SAMPLE_INDEX=4
PING_SCENARIO=healthy
health_collect_locked "$CONFIG_PATH" watchdog
SAMPLE_INDEX=5
health_collect_locked "$CONFIG_PATH" watchdog
assert_eq "$(wc -l < "$history" | tr -d ' ')" 4
head -1 "$history" | grep -q $'^epoch\tclass\tconfidence' || fail "history header missing"

sed -i "s/^epoch=.*/epoch=$(( $(date +%s) - HEALTH_AUTOMTU_MAX_AGE - 1 ))/" "$latest"
if tunnel_health_automtu_gate "$CONFIG_PATH"; then fail "stale health sample allowed Auto-MTU"; fi
assert_eq "$HEALTH_GATE_REASON" health-sample-stale

tunnel_health_invalidate iran1234
[[ ! -f "$latest" ]] || fail "health snapshot was not invalidated"
[[ -f "$history" ]] || fail "invalidation removed bounded history"
}

test_delete_is_scoped() {
local other="${TUNNEL_HEALTH_DIR}/other.latest"
printf 'classification=healthy\n' > "$other"
tunnel_health_delete iran1234
[[ -f "$other" ]] || fail "deleting one tunnel removed another health state"
[[ ! -f "${TUNNEL_HEALTH_DIR}/iran1234.latest" ]] || fail "latest state was not deleted"
[[ ! -f "${TUNNEL_HEALTH_DIR}/iran1234.history.tsv" ]] || fail "history was not deleted"
}

test_classifier_priorities
test_collection_history_and_gate
test_delete_is_scoped
printf 'All Tunnel Health tests passed.\n'

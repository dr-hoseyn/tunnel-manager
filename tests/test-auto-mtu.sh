#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals configure sourced modules under test.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

config_dir="${TEST_ROOT}/config"
service_dir="${TEST_ROOT}/systemd"
CERT_FILE="${TEST_ROOT}/cert.pem"
KEY_FILE="${TEST_ROOT}/key.pem"
mkdir -p "$config_dir" "$service_dir"

AUTOMTU_GOOD_STREAK_REQUIRED=1
AUTOMTU_BAD_STREAK_REQUIRED=1
AUTOMTU_CHANGE_COOLDOWN=0
AUTOMTU_REJECT_COOLDOWN=60
AUTOMTU_MIN_SERVICE_UPTIME=0
AUTOMTU_TRAFFIC_SAMPLE_SECONDS=1
AUTOMTU_SETTLE_SECONDS=0

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/tunnel_health.sh
source "${ROOT_DIR}/lib/tunnel_health.sh"
# shellcheck source=../lib/auto_mtu.sh
source "${ROOT_DIR}/lib/auto_mtu.sh"
# shellcheck source=../core/backhaul/core.sh
source "${ROOT_DIR}/core/backhaul/core.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }

systemctl() {
case "${1:-}" in
is-active|is-enabled) return 0 ;;
restart|daemon-reload) return 0 ;;
show) return 1 ;;
*) return 0 ;;
esac
}
logger() { :; }
tunnel_health_ensure_fresh() { return 0; }
HEALTH_GATE_STATUS=0
tunnel_health_automtu_gate() {
if (( HEALTH_GATE_STATUS == 0 )); then HEALTH_GATE_REASON="healthy"; return 0; fi
HEALTH_GATE_REASON="health-class-network-congestion"
return 1
}

write_ipx_config() {
local path="$1" mtu="$2" name="$3"
cat > "$path" <<EOF
[transport]
type = "tun"

[tun]
encapsulation = "ipx"
name = "${name}"
local_addr = "10.10.10.1/24"
remote_addr = "10.10.10.2/24"
health_port = 1234
mtu = ${mtu}

[ipx]
mode = "server"
profile = "tcp"
listen_ip = "192.0.2.1"
dst_ip = "192.0.2.2"
interface = "eth0"
EOF
}

test_settings_and_scoped_update() {
automtu_save_settings iran1234 true 1200 1420 20
local state_file="${AUTOMTU_STATE_DIR}/iran1234.state"
assert_eq "$(automtu_state_get "$state_file" enabled false)" true
! automtu_validate_settings 999 1420 20 || fail "unsafe minimum accepted"
! automtu_validate_settings 1200 1501 20 || fail "unsafe maximum accepted"
! automtu_validate_settings 1400 1300 20 || fail "reversed range accepted"

local cfg="${config_dir}/scope.toml"
write_ipx_config "$cfg" 1320 scope0
printf '\n[tuning]\n# mtu = 9999\n' >> "$cfg"
automtu_set_config_mtu "$cfg" 1340
assert_eq "$(toml_get "$cfg" tun mtu)" 1340
grep -qF '# mtu = 9999' "$cfg" || fail "non-TUN content was changed"
}

test_metric_guards() {
automtu_candidate_improves up 1292 20 0 1312 20 0 || fail "healthy larger probe was rejected"
! automtu_candidate_improves up 1292 20 0 1312 60 5 || fail "worse larger probe was accepted"
automtu_candidate_improves down 1292 30 40 1272 20 0 || fail "black-hole recovery was rejected"
! automtu_candidate_improves down 1292 30 10 1272 30 10 || fail "smaller MTU without improvement was accepted"
! automtu_small_path_still_healthy 20 0 20 20 || fail "unhealthy control path was accepted"
}

automtu_service_stable() { return 0; }
automtu_system_load_ok() { return 0; }
TRAFFIC_STATUS=1
automtu_service_is_busy() { return "$TRAFFIC_STATUS"; }
automtu_iface_mtu() { toml_get "$CURRENT_CONFIG" tun mtu; }
APPLY_COUNT=0
ROLLBACK_COUNT=0
automtu_apply_candidate() {
local config_path="$1" candidate="$4"
AUTOMTU_BACKUP_PATH=$(mktemp "${TEST_ROOT}/candidate.XXXXXX")
cp -p "$config_path" "$AUTOMTU_BACKUP_PATH"
automtu_set_config_mtu "$config_path" "$candidate"
APPLY_COUNT=$((APPLY_COUNT + 1))
}
automtu_rollback_candidate() {
local config_path="$1" backup_path="$3"
cp -p "$backup_path" "$config_path"
ROLLBACK_COUNT=$((ROLLBACK_COUNT + 1))
}

PING_SCENARIO=""
automtu_ping_metrics() {
local payload="$3"
case "$PING_SCENARIO" in
general_bad) echo "NA 100" ;;
up_good) echo "20 0" ;;
up_reject)
if (( payload > 1292 )); then echo "80 10"; else echo "20 0"; fi
;;
down_good)
if (( payload == 1292 )); then echo "30 40"; else echo "20 0"; fi
;;
*) echo "20 0" ;;
esac
}

prepare_scenario() {
local name="$1"
CURRENT_CONFIG="${config_dir}/${name}.toml"
write_ipx_config "$CURRENT_CONFIG" 1320 "${name}0"
automtu_save_settings "$name" true 1200 1420 20
automtu_reset_learning "$name"
APPLY_COUNT=0
ROLLBACK_COUNT=0
TRAFFIC_STATUS=1
HEALTH_GATE_STATUS=0
}

test_health_classifier_blocks_mtu_changes() {
prepare_scenario healthblock
PING_SCENARIO=up_good
HEALTH_GATE_STATUS=1
automtu_run_locked "$CURRENT_CONFIG" manual
assert_eq "$APPLY_COUNT" 0
assert_eq "$(automtu_state_get "${AUTOMTU_STATE_DIR}/healthblock.state" last_skip none)" health-class-network-congestion
}

test_busy_servers_keep_learning() {
prepare_scenario busy
PING_SCENARIO=up_good
TRAFFIC_STATUS=0
automtu_run_locked "$CURRENT_CONFIG" manual
assert_eq "$APPLY_COUNT" 1
assert_eq "$(automtu_state_get "${AUTOMTU_STATE_DIR}/busy.state" last_traffic none)" high

prepare_scenario busywatchdog
PING_SCENARIO=up_good
TRAFFIC_STATUS=0
AUTOMTU_GOOD_STREAK_REQUIRED=1
automtu_run_locked "$CURRENT_CONFIG" watchdog
automtu_run_locked "$CURRENT_CONFIG" watchdog
assert_eq "$APPLY_COUNT" 0
automtu_run_locked "$CURRENT_CONFIG" watchdog
assert_eq "$APPLY_COUNT" 1

prepare_scenario telemetry
PING_SCENARIO=up_good
TRAFFIC_STATUS=2
automtu_run_locked "$CURRENT_CONFIG" manual
assert_eq "$APPLY_COUNT" 0
assert_eq "$(automtu_state_get "${AUTOMTU_STATE_DIR}/telemetry.state" last_skip none)" traffic-telemetry-unavailable
}

test_watchdog_requires_repeated_evidence() {
prepare_scenario streak
PING_SCENARIO=up_good
AUTOMTU_GOOD_STREAK_REQUIRED=3
automtu_run_locked "$CURRENT_CONFIG" watchdog
automtu_run_locked "$CURRENT_CONFIG" watchdog
assert_eq "$APPLY_COUNT" 0
assert_eq "$(automtu_state_get "${AUTOMTU_STATE_DIR}/streak.state" last_result none)" collecting-up-evidence
automtu_run_locked "$CURRENT_CONFIG" watchdog
assert_eq "$APPLY_COUNT" 1
assert_eq "$(toml_get "$CURRENT_CONFIG" tun mtu)" 1340
AUTOMTU_GOOD_STREAK_REQUIRED=1
}

test_non_mtu_problem_is_ignored() {
prepare_scenario general
PING_SCENARIO=general_bad
automtu_run_locked "$CURRENT_CONFIG" manual
assert_eq "$APPLY_COUNT" 0
assert_eq "$(toml_get "$CURRENT_CONFIG" tun mtu)" 1320
assert_eq "$(automtu_state_get "${AUTOMTU_STATE_DIR}/general.state" last_skip none)" general-network-unhealthy
}

test_upward_candidate_requires_improvement() {
prepare_scenario upgood
PING_SCENARIO=up_good
automtu_run_locked "$CURRENT_CONFIG" manual
assert_eq "$APPLY_COUNT" 1
assert_eq "$ROLLBACK_COUNT" 0
assert_eq "$(toml_get "$CURRENT_CONFIG" tun mtu)" 1340
case "$(automtu_state_get "${AUTOMTU_STATE_DIR}/upgood.state" last_result none)" in
accepted-up-1320-to-1340) : ;;
*) fail "healthy upward candidate was not recorded as accepted" ;;
esac

prepare_scenario upreject
PING_SCENARIO=up_reject
automtu_run_locked "$CURRENT_CONFIG" manual
assert_eq "$APPLY_COUNT" 1
assert_eq "$ROLLBACK_COUNT" 1
assert_eq "$(toml_get "$CURRENT_CONFIG" tun mtu)" 1320
assert_eq "$(automtu_state_get "${AUTOMTU_STATE_DIR}/upreject.state" dynamic_max none)" 1320
}

test_black_hole_recovery_only_when_better() {
prepare_scenario downgood
PING_SCENARIO=down_good
automtu_run_locked "$CURRENT_CONFIG" manual
assert_eq "$APPLY_COUNT" 1
assert_eq "$ROLLBACK_COUNT" 0
assert_eq "$(toml_get "$CURRENT_CONFIG" tun mtu)" 1300
case "$(automtu_state_get "${AUTOMTU_STATE_DIR}/downgood.state" last_result none)" in
accepted-down-1320-to-1300) : ;;
*) fail "improving downward candidate was not recorded as accepted" ;;
esac
}

test_settings_and_scoped_update
test_metric_guards
test_health_classifier_blocks_mtu_changes
test_busy_servers_keep_learning
test_watchdog_requires_repeated_evidence
test_non_mtu_problem_is_ignored
test_upward_candidate_requires_improvement
test_black_hole_recovery_only_when_better
printf 'All Smart Auto-MTU tests passed.\n'

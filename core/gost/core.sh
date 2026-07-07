#!/usr/bin/env bash
# GOST subsystem — deliberately NOT shaped like the Backhaul/Rathole cores.
#
# Backhaul and Rathole are "one config = one systemd service = one tunnel".
# GOST's own native model is different: a single gost process loads ONE
# config file that can hold many named services and many named chains at
# once, and services can optionally route through a chain of hops, each hop
# picking its own protocol (connector) and transport (dialer) independently.
# That per-hop protocol+transport combinability is GOST's actual value over
# Backhaul/Rathole, so this module mirrors GOST's own shape instead of
# forcing it into the per-tunnel pattern: ONE gost.service, ONE gost.yaml,
# built from small per-entity YAML fragments under services.d/ and
# chains.d/ that get concatenated on every change.
#
# Extensibility: GOST_HANDLER_TYPES / GOST_TRANSPORT_TYPES below are the
# single source of truth for what protocols/transports the UI offers.
# Adding support for a new one (GOST adds a transport, or you want to
# expose a protocol this module doesn't list yet) is a one-line addition to
# one of those arrays — every prompt, validator and generator here reads
# from them generically via gost_pick_from_list, none of them hardcode a
# protocol/transport list of their own.
#
# Schema verified against gost.run docs (concepts/chain, tutorials/
# port-forwarding, tutorials/reverse-proxy) and the real v3.2.6 release
# assets — not guessed:
#   services: [{name, addr, handler:{type,chain?}, listener:{type,chain?},
#               forwarder:{nodes:[{name,addr}], selector?:{strategy,...}}}]
#   chains:   [{name, hops:[{name, nodes:[{name,addr,connector:{type},
#               dialer:{type}}]}]}]
# One nuance that matters for correctness: a chain attaches under
# `handler.chain` for forward-proxy-style handlers (tcp/udp/http/socks5/
# relay used as a local proxy), but under `listener.chain` for the reverse
# handlers (rtcp/rudp) — see gost_chain_slot_for_handler.

GOST_REPO="go-gost/gost"
GOST_DIR="${config_dir}/gost"
GOST_BIN="${GOST_DIR}/gost_bin"
GOST_CONFIG="${GOST_DIR}/gost.yaml"
GOST_SERVICES_DIR="${GOST_DIR}/services.d"
GOST_CHAINS_DIR="${GOST_DIR}/chains.d"
GOST_META_DIR="${GOST_DIR}/.meta"
GOST_SERVICE_NAME="gost.service"

GOST_HANDLER_TYPES=(tcp udp rtcp rudp http socks5 relay)
GOST_TRANSPORT_TYPES=(tcp tls ws wss quic kcp grpc h2)
GOST_SELECTOR_STRATEGIES=(round random fifo)

core_gost_ensure_ready() {
mkdir -p "$GOST_DIR" "$GOST_SERVICES_DIR" "$GOST_CHAINS_DIR" "$GOST_META_DIR"
core_gost_install
}

core_gost_install() {
[[ -f "$GOST_BIN" ]] && return 0
mkdir -p "$GOST_DIR"
colorize yellow "Installing GOST..."
local arch asset
arch=$(uname -m)
case "$arch" in
x86_64) asset="linux_amd64" ;;
aarch64|arm64) asset="linux_arm64" ;;
*)
colorize red "Unsupported architecture for GOST: ${arch}."
press_key
return 1
;;
esac
local latest_url tag version
latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${GOST_REPO}/releases/latest" 2>/dev/null)
tag="${latest_url##*/}"
if [[ -z "$tag" ]]; then
colorize red "Could not determine the latest GOST release."
press_key
return 1
fi
version="${tag#v}"
local dl_url="https://github.com/${GOST_REPO}/releases/download/${tag}/gost_${version}_${asset}.tar.gz"
local tmp_dir
tmp_dir=$(mktemp -d)
if ! curl -fsSL "$dl_url" -o "${tmp_dir}/gost.tar.gz"; then
colorize red "Download failed: ${dl_url}"
rm -rf "$tmp_dir"
press_key
return 1
fi
tar -xzf "${tmp_dir}/gost.tar.gz" -C "$tmp_dir"
if [[ ! -f "${tmp_dir}/gost" ]]; then
colorize red "Downloaded archive did not contain the expected 'gost' binary."
rm -rf "$tmp_dir"
press_key
return 1
fi
local tmp_bin
tmp_bin=$(mktemp "${GOST_DIR}/.gost_bin.XXXXXX")
cp "${tmp_dir}/gost" "$tmp_bin"
chmod +x "$tmp_bin"
mv -f "$tmp_bin" "$GOST_BIN"
rm -rf "$tmp_dir"
if ! "$GOST_BIN" -V &> /dev/null; then
colorize red "GOST binary failed a basic sanity check (-V)."
rm -f "$GOST_BIN"
press_key
return 1
fi
colorize green "✔ GOST ${tag} installed."
}

# Generic, registry-driven picker: prompts with a default, validates against
# an arbitrary list of allowed values, writes the result into $3 by name
# (same indirect-assignment convention as prompt_with_default/prompt_boolean
# elsewhere in this codebase, so it composes with them and never leaks its
# own prompt output into a command-substitution capture).
gost_pick_from_list() {
local label="$1" default="$2" var_name="$3"
shift 3
local -a choices=("$@")
local input
colorize magenta "Available: ${choices[*]}"
while true; do
prompt_with_default "$label" "$default" input
input="${input,,}"
if [[ " ${choices[*]} " == *" ${input} "* ]]; then
eval "$var_name=\"\$input\""
return 0
fi
colorize red "Invalid choice. Pick one of: ${choices[*]}"
done
}

gost_chain_slot_for_handler() {
local handler_type="$1"
case "$handler_type" in
rtcp|rudp) echo "listener" ;;
*) echo "handler" ;;
esac
}

gost_detect_default_gateway() {
ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}'
}

gost_meta_set() {
local name="$1" key="$2" value="$3"
local f="${GOST_META_DIR}/${name}.conf"
mkdir -p "$GOST_META_DIR"
touch "$f"
grep -qxE "^${key}=.*" "$f" 2>/dev/null && sed -i "/^${key}=/d" "$f"
echo "${key}=${value}" >> "$f"
}

gost_meta_get() {
local name="$1" key="$2"
local f="${GOST_META_DIR}/${name}.conf"
[[ -f "$f" ]] || return 1
grep "^${key}=" "$f" 2>/dev/null | tail -1 | cut -d= -f2-
}

gost_rebuild_config() {
{
echo "services:"
local f
for f in "${GOST_SERVICES_DIR}"/*.yaml; do
[[ -f "$f" ]] || continue
cat "$f"
done
echo "chains:"
for f in "${GOST_CHAINS_DIR}"/*.yaml; do
[[ -f "$f" ]] || continue
cat "$f"
done
} > "$GOST_CONFIG"
}

gost_apply_and_restart() {
local backup_dir
backup_dir=$(backup_tunnel "$GOST_CONFIG" "${service_dir}/${GOST_SERVICE_NAME}" "gost")
gost_rebuild_config
if [[ ! -f "${service_dir}/${GOST_SERVICE_NAME}" ]]; then
core_gost_create_service
fi
systemctl restart "$GOST_SERVICE_NAME"
sleep 2
if systemctl is-active --quiet "$GOST_SERVICE_NAME"; then
colorize green "✔ Applied and gost.service is healthy."
rm -rf "$backup_dir"
return 0
else
colorize red "✘ gost.service failed to come back up! Rolling back..."
restore_tunnel_backup "$backup_dir" "$GOST_CONFIG" "${service_dir}/${GOST_SERVICE_NAME}" "$GOST_SERVICE_NAME"
if systemctl is-active --quiet "$GOST_SERVICE_NAME"; then
colorize green "✔ Rollback succeeded."
else
colorize red "✘ Rollback also failed! Check logs manually: journalctl -eu ${GOST_SERVICE_NAME}"
fi
press_key
return 1
fi
}

core_gost_create_service() {
local service_file="${service_dir}/${GOST_SERVICE_NAME}"
cat > "$service_file" <<EOF
[Unit]
Description=GOST tunnel daemon
After=network.target
[Service]
Type=simple
User=root
ExecStart=${GOST_BIN} -C ${GOST_CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=1048576
IPAccounting=yes
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$GOST_SERVICE_NAME" >/dev/null 2>&1
}

gost_generate_service_fragment() {
local name="$1" handler_type="$2" listener_type="$3" addr="$4" chain_name="$5" nodes_csv="$6" strategy="$7"
local chain_slot
chain_slot=$(gost_chain_slot_for_handler "$handler_type")
local f="${GOST_SERVICES_DIR}/${name}.yaml"
{
echo "- name: ${name}"
echo "  addr: \"${addr}\""
echo "  handler:"
echo "    type: ${handler_type}"
if [[ -n "$chain_name" && "$chain_slot" == "handler" ]]; then
echo "    chain: ${chain_name}"
fi
echo "  listener:"
echo "    type: ${listener_type}"
if [[ -n "$chain_name" && "$chain_slot" == "listener" ]]; then
echo "    chain: ${chain_name}"
fi
local -a nodes=()
IFS=',' read -r -a nodes <<< "$nodes_csv"
if [[ "${#nodes[@]}" -gt 0 && -n "${nodes[0]}" ]]; then
echo "  forwarder:"
echo "    nodes:"
local i=0 node
for node in "${nodes[@]}"; do
node="${node// /}"
[[ -z "$node" ]] && continue
echo "    - name: ${name}-${i}"
echo "      addr: \"${node}\""
((i++))
done
if (( i > 1 )); then
echo "    selector:"
echo "      strategy: ${strategy:-round}"
echo "      maxFails: 1"
echo "      failTimeout: 30s"
fi
fi
} > "$f"
}

# tun2socks: routes this server's own traffic through a chain (a remote
# relay/socks5 service, built with the existing Services/Chains features) by
# bringing up a TUN device and rewriting the default route through it. The
# postUp sequence always re-adds the original default route at a higher
# metric (10) before adding the tun route at metric 1 — GOST's own
# documented pattern for this, not a panel invention — so if the tun
# interface ever goes down, the kernel drops its route automatically and
# traffic falls back to the original path with no manual cleanup needed.
# GOST has no postDown hook to pair with postUp, which is exactly why this
# fallback-route pattern matters: it's the only teardown safety net there is.
gost_generate_tungo_fragment() {
local name="$1" chain_name="$2" tun_net="$3" tun_mtu="$4" tun_dns="$5" gateway_ip="$6" gateway_iface="$7"
local f="${GOST_SERVICES_DIR}/${name}.yaml"
{
echo "- name: ${name}"
echo "  addr: \":0\""
echo "  handler:"
echo "    type: tungo"
echo "    chain: ${chain_name}"
echo "  listener:"
echo "    type: tungo"
echo "    metadata:"
echo "      name: ${name}"
echo "      net: \"${tun_net}\""
echo "      mtu: ${tun_mtu}"
[[ -n "$tun_dns" ]] && echo "      dns: ${tun_dns}"
echo "  metadata:"
echo "    postUp:"
echo "    - ip route delete default"
echo "    - ip route add default via ${gateway_ip} dev ${gateway_iface} metric 10"
echo "    - ip route add default dev ${name} metric 1"
} > "$f"
}

gost_generate_chain_fragment() {
local name="$1" hops_file="$2"
local f="${GOST_CHAINS_DIR}/${name}.yaml"
{
echo "- name: ${name}"
echo "  hops:"
local i=0 addr connector dialer
while IFS=$'\t' read -r addr connector dialer; do
[[ -z "$addr" ]] && continue
echo "  - name: ${name}-hop${i}"
echo "    nodes:"
echo "    - name: ${name}-hop${i}-node0"
echo "      addr: \"${addr}\""
echo "      connector:"
echo "        type: ${connector}"
echo "      dialer:"
echo "        type: ${dialer}"
((i++))
done < "$hops_file"
} > "$f"
}

core_gost_list_services() {
local f
for f in "${GOST_SERVICES_DIR}"/*.yaml; do
[[ -f "$f" ]] || continue
basename "${f%.yaml}"
done
}

core_gost_list_chains() {
local f
for f in "${GOST_CHAINS_DIR}"/*.yaml; do
[[ -f "$f" ]] || continue
basename "${f%.yaml}"
done
}

core_gost_quick_start() {
core_gost_ensure_ready
clear
colorize cyan "GOST Quick Start — simple port forward" bold
echo ""
colorize yellow "This creates a plain TCP or UDP forward: traffic hitting a port here goes"
colorize yellow "straight to one or more targets, no chain/protocol hopping. For chained"
colorize yellow "protocols (relay/socks5/http over tls/ws/quic/...), use Services (advanced)"
colorize yellow "and Chains from the GOST Manager menu instead."
echo ""
local name proto listen_port targets_csv
prompt_with_default "Service name" "quickfwd$((RANDOM % 1000))" name
if [[ -f "${GOST_SERVICES_DIR}/${name}.yaml" ]]; then
colorize red "A GOST service named '${name}' already exists."
press_key
return 1
fi
gost_pick_from_list "Protocol" "tcp" proto tcp udp
prompt_with_default "Listen port" "8080" listen_port
echo ""
colorize green "Target(s) this forwards to — comma-separated host:port. More than one"
colorize green "enables GOST's built-in round-robin load balancing across them."
prompt_with_default "Target(s)" "" targets_csv
if [[ -z "$targets_csv" ]]; then
colorize red "At least one target is required."
press_key
return 1
fi
gost_generate_service_fragment "$name" "$proto" "$proto" ":${listen_port}" "" "$targets_csv" "round"
gost_apply_and_restart
echo ""
press_key
}

core_gost_add_service_advanced() {
core_gost_ensure_ready
clear
colorize cyan "GOST Service — advanced" bold
echo ""
local name handler_type listener_type addr chain_name targets_csv strategy
prompt_with_default "Service name" "svc$((RANDOM % 1000))" name
if [[ -f "${GOST_SERVICES_DIR}/${name}.yaml" ]]; then
colorize red "A GOST service named '${name}' already exists. Use Edit instead."
press_key
return 1
fi
gost_pick_from_list "Handler (protocol)" "tcp" handler_type "${GOST_HANDLER_TYPES[@]}"
gost_pick_from_list "Listener (transport for incoming connections)" "tcp" listener_type "${GOST_TRANSPORT_TYPES[@]}"
prompt_with_default "Listen address" ":8080" addr
[[ "$addr" != *:* ]] && addr=":${addr}"

local -a existing_chains=()
mapfile -t existing_chains < <(core_gost_list_chains)
chain_name=""
if [[ "${#existing_chains[@]}" -gt 0 ]]; then
echo ""
colorize magenta "Existing chains: ${existing_chains[*]}"
prompt_with_default "Attach a chain? (name, or blank for none)" "" chain_name
if [[ -n "$chain_name" ]] && [[ ! -f "${GOST_CHAINS_DIR}/${chain_name}.yaml" ]]; then
colorize red "No such chain '${chain_name}'. Create it first from the Chains menu."
press_key
return 1
fi
fi

echo ""
colorize green "Target(s) this service forwards to — comma-separated host:port"
colorize yellow "(leave blank if this service only proxies through the chain, e.g. socks5/http)"
prompt_with_default "Target(s)" "" targets_csv
strategy="round"
if [[ "$targets_csv" == *,* ]]; then
gost_pick_from_list "Load-balancing strategy" "round" strategy "${GOST_SELECTOR_STRATEGIES[@]}"
fi

gost_generate_service_fragment "$name" "$handler_type" "$listener_type" "$addr" "$chain_name" "$targets_csv" "$strategy"
gost_meta_set "$name" "handler_type" "$handler_type"
gost_apply_and_restart
echo ""
press_key
}

core_gost_add_tungo() {
core_gost_ensure_ready
clear
colorize cyan "GOST TUN2SOCKS — route this server's own traffic through a chain" bold
echo ""
colorize red "WARNING: this replaces this server's default route." bold
colorize yellow "A fallback route at a higher metric is added automatically (GOST's own"
colorize yellow "documented pattern), so losing the tun interface shouldn't drop"
colorize yellow "connectivity — but this still changes system-wide routing. If you're not"
colorize yellow "certain, test with your provider's console open, not only over SSH."
echo ""

local -a existing_chains=()
mapfile -t existing_chains < <(core_gost_list_chains)
if [[ "${#existing_chains[@]}" -eq 0 ]]; then
colorize red "No chains exist yet. Create one first from GOST Manager -> Chains — it"
colorize red "should point at a relay/socks5-type service on the remote server you want"
colorize red "to route through."
press_key
return 1
fi
colorize magenta "Existing chains: ${existing_chains[*]}"
local chain_name
prompt_with_default "Chain to route through" "${existing_chains[0]}" chain_name
if [[ ! -f "${GOST_CHAINS_DIR}/${chain_name}.yaml" ]]; then
colorize red "No such chain '${chain_name}'."
press_key
return 1
fi

local gateway_ip gateway_iface
gateway_ip=$(gost_detect_default_gateway)
gateway_iface=$(detect_default_interface)
if [[ -z "$gateway_ip" || -z "$gateway_iface" ]]; then
colorize red "Could not auto-detect this server's current default gateway/interface —"
colorize red "refusing to generate a routing change that can't be verified safe."
press_key
return 1
fi
echo ""
colorize yellow "Detected current default route: via ${gateway_ip} dev ${gateway_iface} (kept as the fallback)"
echo ""

local name tun_net tun_mtu tun_dns
prompt_with_default "TUN device name" "tungo0" name
if [[ -f "${GOST_SERVICES_DIR}/${name}.yaml" ]]; then
colorize red "A GOST service named '${name}' already exists."
press_key
return 1
fi
prompt_with_default "TUN network (CIDR)" "192.168.123.1/24" tun_net
prompt_with_default "MTU" "1420" tun_mtu
prompt_with_default "DNS server (optional)" "1.1.1.1" tun_dns

gost_generate_tungo_fragment "$name" "$chain_name" "$tun_net" "$tun_mtu" "$tun_dns" "$gateway_ip" "$gateway_iface"
gost_meta_set "$name" "handler_type" "tungo"
gost_apply_and_restart
echo ""
colorize yellow "If this server becomes unreachable: use your provider's console to run"
colorize yellow "'systemctl stop gost.service', then remove '${name}' from GOST Manager -> Services."
press_key
}

core_gost_remove_service() {
local name="$1"
rm -f "${GOST_SERVICES_DIR}/${name}.yaml" "${GOST_META_DIR}/${name}.conf"
gost_apply_and_restart
}

core_gost_service_menu() {
while true; do
clear
colorize cyan "GOST Services" bold
echo ""
local -a services=()
mapfile -t services < <(core_gost_list_services)
if [[ "${#services[@]}" -eq 0 ]]; then
colorize yellow "(no services configured yet)"
else
local i=1 s
for s in "${services[@]}"; do
echo "  $i) $s"
((i++))
done
fi
echo ""
colorize green "a) Add service (advanced)"
colorize red "d) Remove a service"
echo "0) Back"
read -r -p "Choice: " choice
case "$choice" in
a) core_gost_add_service_advanced ;;
d)
if [[ "${#services[@]}" -eq 0 ]]; then
colorize red "Nothing to remove."; sleep 1
else
read -r -p "Number to remove: " idx
if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#services[@]} )); then
core_gost_remove_service "${services[$((idx-1))]}"
else
colorize red "Invalid choice"; sleep 1
fi
fi
;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}

core_gost_add_chain() {
clear
colorize cyan "GOST Chain — add" bold
echo ""
colorize yellow "A chain is an ordered list of hops. Traffic goes through hop 1, then hop 2,"
colorize yellow "and so on, each hop free to use its own protocol (connector) and transport"
colorize yellow "(dialer) — this is GOST's actual chaining/flexibility feature."
echo ""
local name
prompt_with_default "Chain name" "chain$((RANDOM % 1000))" name
if [[ -f "${GOST_CHAINS_DIR}/${name}.yaml" ]]; then
colorize red "A chain named '${name}' already exists. Use Edit instead."
press_key
return 1
fi
local hops_file
hops_file=$(mktemp "${GOST_META_DIR}/.hops.XXXXXX")
core_gost_hop_editor "$hops_file"
if [[ ! -s "$hops_file" ]]; then
colorize red "A chain needs at least one hop."
rm -f "$hops_file"
press_key
return 1
fi
gost_generate_chain_fragment "$name" "$hops_file"
mv -f "$hops_file" "${GOST_META_DIR}/${name}.hops"
gost_apply_and_restart
echo ""
press_key
}

core_gost_hop_editor() {
local hops_file="$1"
touch "$hops_file"
while true; do
clear
colorize cyan "Hops (in order)" bold
echo ""
local i=1 addr connector dialer
if [[ -s "$hops_file" ]]; then
while IFS=$'\t' read -r addr connector dialer; do
echo "  $i) ${addr}  (${connector} over ${dialer})"
((i++))
done < "$hops_file"
else
colorize yellow "(no hops yet)"
fi
echo ""
colorize green "a) Add a hop"
colorize red "d) Remove a hop"
echo "f) Finish"
read -r -p "Choice: " choice
case "$choice" in
a)
local hop_addr hop_connector hop_dialer
prompt_with_default "Hop address (host:port)" "" hop_addr
if [[ -z "$hop_addr" ]]; then
colorize red "Address required."; sleep 1; continue
fi
gost_pick_from_list "Connector (protocol for this hop)" "relay" hop_connector "${GOST_HANDLER_TYPES[@]}"
gost_pick_from_list "Dialer (transport for this hop)" "tcp" hop_dialer "${GOST_TRANSPORT_TYPES[@]}"
printf '%s\t%s\t%s\n' "$hop_addr" "$hop_connector" "$hop_dialer" >> "$hops_file"
;;
d)
if [[ ! -s "$hops_file" ]]; then
colorize red "Nothing to remove."; sleep 1
else
read -r -p "Number to remove: " idx
if [[ "$idx" =~ ^[0-9]+$ ]]; then
sed -i "${idx}d" "$hops_file" 2>/dev/null
else
colorize red "Invalid choice"; sleep 1
fi
fi
;;
f) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}

core_gost_remove_chain() {
local name="$1"
rm -f "${GOST_CHAINS_DIR}/${name}.yaml" "${GOST_META_DIR}/${name}.hops"
gost_apply_and_restart
}

core_gost_chain_menu() {
while true; do
clear
colorize cyan "GOST Chains" bold
echo ""
local -a chains=()
mapfile -t chains < <(core_gost_list_chains)
if [[ "${#chains[@]}" -eq 0 ]]; then
colorize yellow "(no chains configured yet)"
else
local i=1 c
for c in "${chains[@]}"; do
echo "  $i) $c"
((i++))
done
fi
echo ""
colorize green "a) Add chain"
colorize red "d) Remove a chain"
echo "0) Back"
read -r -p "Choice: " choice
case "$choice" in
a) core_gost_add_chain ;;
d)
if [[ "${#chains[@]}" -eq 0 ]]; then
colorize red "Nothing to remove."; sleep 1
else
read -r -p "Number to remove: " idx
if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#chains[@]} )); then
core_gost_remove_chain "${chains[$((idx-1))]}"
else
colorize red "Invalid choice"; sleep 1
fi
fi
;;
0) return ;;
*) colorize red "Invalid choice"; sleep 1 ;;
esac
done
}

core_gost_diagnostics() {
clear
colorize cyan "GOST Diagnostics" bold
echo ""
if systemctl is-active --quiet "$GOST_SERVICE_NAME"; then
colorize green "✔ gost.service is active"
else
colorize red "✘ gost.service is not active"
fi
echo ""
local -a services=()
mapfile -t services < <(core_gost_list_services)
if [[ "${#services[@]}" -eq 0 ]]; then
colorize yellow "No services configured."
else
local s addr port
for s in "${services[@]}"; do
addr=$(grep -m1 '^  addr:' "${GOST_SERVICES_DIR}/${s}.yaml" 2>/dev/null | sed -E 's/.*addr: *"?([^"]*)"?/\1/')
port="${addr##*:}"
if [[ -n "$port" ]] && tcp_port_open "127.0.0.1" "$port" 2; then
colorize green "✔ ${s} (${addr}) — listening"
else
colorize red "✘ ${s} (${addr}) — not responding locally"
fi
done
fi
echo ""
local traffic
traffic=$(tunnel_traffic_stats "$GOST_SERVICE_NAME")
[[ -n "$traffic" ]] && echo "Traffic: ${traffic}"
echo ""
press_key
}

core_gost_watchdog_check() {
[[ -f "$GOST_CONFIG" ]] || return 0
if ! systemctl is-active --quiet "$GOST_SERVICE_NAME" 2>/dev/null; then
logger -t gost-watchdog "${GOST_SERVICE_NAME} is inactive, restarting" 2>/dev/null
systemctl restart "$GOST_SERVICE_NAME" 2>/dev/null
fi
}

core_gost_destroy_all() {
systemctl disable --now "$GOST_SERVICE_NAME" >/dev/null 2>&1
rm -f "${service_dir}/${GOST_SERVICE_NAME}"
systemctl daemon-reload
}

core_gost_menu() {
core_gost_ensure_ready
while true; do
clear
colorize cyan "GOST Manager" bold
echo ""
colorize green " 1. Quick Start (simple TCP/UDP forward)" bold
colorize magenta " 2. Services (advanced)" bold
colorize magenta " 3. Chains (protocol/transport chaining)" bold
colorize red " 4. TUN2SOCKS (route this server's traffic through a chain)" bold
colorize cyan " 5. Diagnostics" bold
echo " 6. View logs"
echo " 7. Restart gost"
echo " 0. Back"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Enter your choice [0-7]: " choice
case "$choice" in
1) core_gost_quick_start ;;
2) core_gost_service_menu ;;
3) core_gost_chain_menu ;;
4) core_gost_add_tungo ;;
5) core_gost_diagnostics ;;
6) view_service_logs "$GOST_SERVICE_NAME" ;;
7) restart_service "$GOST_SERVICE_NAME" ;;
0) return ;;
*) colorize red "Invalid option!"; sleep 1 ;;
esac
done
}

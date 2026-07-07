#!/usr/bin/env bash
set -e

REPO="dr-hoseyn/tunnel-manager"
REPO_RAW="https://raw.githubusercontent.com/${REPO}/main"
CONFIG_DIR="/root/backhaul-core"
INSTALL_DIR="/opt/tunnel-manager"
PANEL_PATH="/usr/local/bin/backhaul"
TUNNEL_MANAGER_PATH="/usr/local/bin/tunnel-manager"

if [[ $EUID -ne 0 ]]; then
echo "This installer must be run as root." >&2
exit 1
fi

if ! command -v curl &> /dev/null; then
echo "curl is required but not installed. Install it first (e.g. apt install curl)." >&2
exit 1
fi

mkdir -p "$CONFIG_DIR"
mkdir -p "$INSTALL_DIR"
mkdir -p "$(dirname "$PANEL_PATH")"

# Download to a temp file in the SAME directory as the final path, then move it
# into place atomically. A previous tunnel's systemd service may currently be
# running this exact binary/script, and overwriting a running executable
# in place can fail (or corrupt it) on Linux; an atomic rename never does.
echo "Downloading Backhaul core..."
TMP_CORE=$(mktemp "${CONFIG_DIR}/.backhaul_premium.XXXXXX")
curl -fsSL "$REPO_RAW/backhaul_premium" -o "$TMP_CORE"

EXPECTED_SHA=$(curl -fsSL "$REPO_RAW/backhaul_premium.sha256" 2>/dev/null | awk '{print $1}')
if [[ -n "$EXPECTED_SHA" ]]; then
ACTUAL_SHA=""
if command -v sha256sum &> /dev/null; then
ACTUAL_SHA=$(sha256sum "$TMP_CORE" | awk '{print $1}')
elif command -v openssl &> /dev/null; then
ACTUAL_SHA=$(openssl dgst -sha256 "$TMP_CORE" | awk '{print $NF}')
fi
if [[ -n "$ACTUAL_SHA" && "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
echo "Checksum mismatch for backhaul_premium (expected $EXPECTED_SHA, got $ACTUAL_SHA). Aborting." >&2
rm -f "$TMP_CORE"
exit 1
fi
fi

chmod +x "$TMP_CORE"
mv -f "$TMP_CORE" "$CONFIG_DIR/backhaul_premium"

echo "Downloading Tunnel Manager..."
TMP_DIR=$(mktemp -d)
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" -o "${TMP_DIR}/src.tar.gz"
tar -xzf "${TMP_DIR}/src.tar.gz" -C "$TMP_DIR"
EXTRACTED=$(find "$TMP_DIR" -maxdepth 1 -type d -name "tunnel-manager-*" | head -1)
if [[ -z "$EXTRACTED" ]]; then
echo "Unexpected archive layout from ${REPO}." >&2
rm -rf "$TMP_DIR"
exit 1
fi

# Stage into a sibling temp dir inside INSTALL_DIR's parent, then swap the
# whole tree in with one mv — same atomic-replace reasoning as the core
# binary above, but for a directory instead of a single file.
TMP_INSTALL=$(mktemp -d "$(dirname "$INSTALL_DIR")/.tunnel-manager.XXXXXX")
cp -r "${EXTRACTED}/lib" "${EXTRACTED}/core" "${EXTRACTED}/tunnel-manager.sh" "$TMP_INSTALL/"
chmod +x "${TMP_INSTALL}/tunnel-manager.sh"
rm -rf "$INSTALL_DIR"
mv -f "$TMP_INSTALL" "$INSTALL_DIR"
rm -rf "$TMP_DIR"

write_wrapper() {
local target="$1"
local tmp
tmp=$(mktemp "$(dirname "$target")/.wrapper.XXXXXX")
cat > "$tmp" <<EOF
#!/usr/bin/env bash
exec "${INSTALL_DIR}/tunnel-manager.sh" "\$@"
EOF
chmod +x "$tmp"
mv -f "$tmp" "$target"
}
write_wrapper "$PANEL_PATH"
write_wrapper "$TUNNEL_MANAGER_PATH"

echo "Installed. Launching panel..."
echo ""
exec "$PANEL_PATH"

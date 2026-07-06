#!/usr/bin/env bash
set -e

REPO_RAW="https://raw.githubusercontent.com/dr-hoseyn/tunnel-manager/main"
CONFIG_DIR="/root/backhaul-core"
PANEL_PATH="/usr/local/bin/backhaul"

if [[ $EUID -ne 0 ]]; then
echo "This installer must be run as root." >&2
exit 1
fi

if ! command -v curl &> /dev/null; then
echo "curl is required but not installed. Install it first (e.g. apt install curl)." >&2
exit 1
fi

mkdir -p "$CONFIG_DIR"
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

echo "Downloading management panel..."
TMP_PANEL=$(mktemp "$(dirname "$PANEL_PATH")/.backhaul.XXXXXX")
curl -fsSL "$REPO_RAW/backhaul.sh" -o "$TMP_PANEL"
chmod +x "$TMP_PANEL"
mv -f "$TMP_PANEL" "$PANEL_PATH"

echo "Installed. Launching panel..."
echo ""
exec bash "$PANEL_PATH"

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

echo "Downloading Backhaul core..."
curl -fsSL "$REPO_RAW/backhaul_premium" -o "$CONFIG_DIR/backhaul_premium"
chmod +x "$CONFIG_DIR/backhaul_premium"

echo "Downloading management panel..."
curl -fsSL "$REPO_RAW/backhaul.sh" -o "$PANEL_PATH"
chmod +x "$PANEL_PATH"

echo "Installed. Launching panel..."
echo ""
exec bash "$PANEL_PATH"

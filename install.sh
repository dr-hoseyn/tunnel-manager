#!/usr/bin/env bash
set -e

REPO="dr-hoseyn/tunnel-manager"
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

case "$(uname -m)" in
x86_64) ;;
*)
echo "The bundled verified Backhaul Premium binary currently supports x86_64 only." >&2
echo "Add a separately checksummed binary for this architecture before installing." >&2
exit 1
;;
esac

mkdir -p "$CONFIG_DIR"
mkdir -p "$(dirname "$INSTALL_DIR")"
mkdir -p "$(dirname "$PANEL_PATH")"

# Resolve main once and fetch the source, core, and checksum from that exact
# immutable commit. This avoids mixing files if main changes mid-install.
COMMIT_SHA=$(curl -fsSL "https://api.github.com/repos/${REPO}/commits/main" |
sed -n 's/^[[:space:]]*"sha": "\([0-9a-f]\{40\}\)",*$/\1/p' | head -1)
if [[ ! "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
echo "Could not resolve an immutable repository commit." >&2
exit 1
fi
REPO_RAW="https://raw.githubusercontent.com/${REPO}/${COMMIT_SHA}"

# Download to a temp file in the SAME directory as the final path, then move it
# into place atomically. A previous tunnel's systemd service may currently be
# running this exact binary/script, and overwriting a running executable
# in place can fail (or corrupt it) on Linux; an atomic rename never does.
echo "Downloading Backhaul core..."
TMP_CORE=$(mktemp "${CONFIG_DIR}/.backhaul_premium.XXXXXX")
if ! EXPECTED_SHA=$(curl -fsSL "$REPO_RAW/backhaul_premium.sha256" | awk '{print $1}'); then
echo "Could not download the Backhaul checksum; refusing an unverified install." >&2
rm -f "$TMP_CORE"
exit 1
fi
if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
echo "The Backhaul checksum is malformed; refusing installation." >&2
rm -f "$TMP_CORE"
exit 1
fi
if ! curl -fsSL "$REPO_RAW/backhaul_premium" -o "$TMP_CORE"; then
rm -f "$TMP_CORE"
exit 1
fi
ACTUAL_SHA=""
if command -v sha256sum &> /dev/null; then
ACTUAL_SHA=$(sha256sum "$TMP_CORE" | awk '{print $1}')
elif command -v openssl &> /dev/null; then
ACTUAL_SHA=$(openssl dgst -sha256 "$TMP_CORE" | awk '{print $NF}')
else
echo "sha256sum or openssl is required to verify Backhaul." >&2
rm -f "$TMP_CORE"
exit 1
fi
if [[ "${ACTUAL_SHA,,}" != "${EXPECTED_SHA,,}" ]]; then
echo "Checksum mismatch for backhaul_premium (expected $EXPECTED_SHA, got $ACTUAL_SHA). Aborting." >&2
rm -f "$TMP_CORE"
exit 1
fi

chmod +x "$TMP_CORE"
if ! "$TMP_CORE" -v >/dev/null 2>&1; then
echo "Verified Backhaul binary failed its version sanity check." >&2
rm -f "$TMP_CORE"
exit 1
fi

echo "Downloading Tunnel Manager..."
TMP_DIR=$(mktemp -d)
curl -fsSL "https://github.com/${REPO}/archive/${COMMIT_SHA}.tar.gz" -o "${TMP_DIR}/src.tar.gz"
if ! tar -xzf "${TMP_DIR}/src.tar.gz" -C "$TMP_DIR"; then
echo "Downloaded source archive is invalid; installation aborted." >&2
rm -rf "$TMP_DIR"
exit 1
fi
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
for STAGED_FILE in "${TMP_INSTALL}/tunnel-manager.sh" "${TMP_INSTALL}"/lib/*.sh "${TMP_INSTALL}"/core/*/*.sh; do
if ! bash -n "$STAGED_FILE"; then
echo "Syntax validation failed for $(basename "$STAGED_FILE"); installation aborted." >&2
rm -rf "$TMP_INSTALL" "$TMP_DIR"
exit 1
fi
done
OLD_CORE=""
if [[ -f "$CONFIG_DIR/backhaul_premium" ]]; then
OLD_CORE=$(mktemp "${CONFIG_DIR}/.backhaul_previous.XXXXXX")
cp -p "$CONFIG_DIR/backhaul_premium" "$OLD_CORE"
fi
mv -f "$TMP_CORE" "$CONFIG_DIR/backhaul_premium"
OLD_INSTALL="${INSTALL_DIR}.previous.$$"
if [[ -d "$INSTALL_DIR" ]]; then
mv "$INSTALL_DIR" "$OLD_INSTALL"
fi
if ! mv "$TMP_INSTALL" "$INSTALL_DIR"; then
[[ -d "$OLD_INSTALL" ]] && mv "$OLD_INSTALL" "$INSTALL_DIR"
if [[ -n "$OLD_CORE" ]]; then mv -f "$OLD_CORE" "$CONFIG_DIR/backhaul_premium"; else rm -f "$CONFIG_DIR/backhaul_premium"; fi
echo "Could not activate the new Tunnel Manager tree; previous installation restored." >&2
rm -rf "$TMP_DIR"
exit 1
fi
[[ -n "$OLD_CORE" ]] && rm -f "$OLD_CORE"
[[ -d "$OLD_INSTALL" ]] && rm -rf "$OLD_INSTALL"
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

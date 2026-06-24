#!/usr/bin/env bash
# Open Design Linux setup: extract the macOS DMG payload, rebuild native
# modules for Linux Electron, and wire a runnable layout for electron-builder.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${1:-${ROOT_DIR}/open-design.dmg}"
SKIP_APP_INSTALL="${SKIP_APP_INSTALL:-0}"

print_usage() {
  cat <<EOF
Usage:
  bash scripts/setup.sh /path/to/open-design-<ver>-mac-x64.dmg
  bash scripts/setup.sh

Notes:
  - Default DMG path: ${ROOT_DIR}/open-design.dmg
  - Set SKIP_APP_INSTALL=1 to skip the local ~/.local/bin launcher (CI uses this)
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    return 1
  fi
}

echo "== Open Design Linux setup =="

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_usage
  exit 0
fi

need_cmd node
need_cmd npm

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found: ${DMG_PATH}" >&2
  print_usage >&2
  exit 1
fi

echo "[1/5] Installing npm dependencies..."
( cd "${ROOT_DIR}" && npm install --include=dev )

echo "[2/5] Extracting app payload from DMG..."
bash "${ROOT_DIR}/scripts/internal/extract-dmg.sh" "${DMG_PATH}"

echo "[3/5] Rebuilding native modules for Linux..."
bash "${ROOT_DIR}/scripts/internal/build-native.sh"

echo "[4/5] Running smoke check..."
ELECTRON_BIN="${ROOT_DIR}/node_modules/.bin/electron"
if [[ -x "${ELECTRON_BIN}" ]]; then
  "${ELECTRON_BIN}" --version >/dev/null || true
fi

if [[ "${SKIP_APP_INSTALL}" == "1" ]]; then
  echo "[5/5] Skipped local launcher install (SKIP_APP_INSTALL=1)."
  echo
  echo "Payload ready for packaging in: ${ROOT_DIR}/app_asar"
  exit 0
fi

echo "[5/5] Installing local launcher..."
mkdir -p "${HOME}/.local/bin"
cat > "${HOME}/.local/bin/open-design" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${ROOT_DIR}"
APP_DIR="\${ROOT_DIR}/app_asar/app"
if [[ ! -d "\${APP_DIR}" ]]; then
  echo "Missing \${APP_DIR}. Re-run: bash \${ROOT_DIR}/scripts/setup.sh /path/to/open-design.dmg" >&2
  exit 1
fi
ELECTRON_BIN="\${ELECTRON_BIN:-}"
if [[ -z "\${ELECTRON_BIN}" ]]; then
  if [[ -x "\${ROOT_DIR}/node_modules/.bin/electron" ]]; then
    ELECTRON_BIN="\${ROOT_DIR}/node_modules/.bin/electron"
  elif command -v electron >/dev/null 2>&1; then
    ELECTRON_BIN="\$(command -v electron)"
  else
    echo "electron not found. Run npm install in \${ROOT_DIR}." >&2
    exit 1
  fi
fi
export ELECTRON_FORCE_IS_PACKAGED=1
export NODE_ENV=production
EXTRA=()
EXTRA+=(--no-sandbox --disable-gpu)
[[ -n "\${WAYLAND_DISPLAY:-}" ]] && EXTRA+=(--ozone-platform=wayland) || EXTRA+=(--ozone-platform=x11)
EXTRA+=(--password-store=basic)
exec "\${ELECTRON_BIN}" "\${EXTRA[@]}" "\${APP_DIR}" "\$@"
EOF
chmod +x "${HOME}/.local/bin/open-design"
echo "  Installed: ${HOME}/.local/bin/open-design"

mkdir -p "${HOME}/.local/share/applications"
cat > "${HOME}/.local/share/applications/open-design.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Open Design
Comment=Open Design Desktop (Linux)
Exec=${HOME}/.local/bin/open-design
Terminal=false
Icon=open-design
Categories=Graphics;Development;
StartupNotify=true
EOF
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "${HOME}/.local/share/applications" || true
fi

echo
echo "Open Design Linux setup complete."
echo "Run:    ${HOME}/.local/bin/open-design"
echo "Menu:   Open Design"

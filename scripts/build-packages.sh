#!/usr/bin/env bash
# Build Open Design Linux packages (DEB and/or AppImage) from an already-set-up
# payload in app_asar/. If the payload is missing and a DMG is provided, setup
# runs automatically first.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app_asar/app"
TARGET="${1:-all}"
DMG_PATH="${2:-}"

print_usage() {
  cat <<EOF
Usage:
  bash scripts/build-packages.sh [deb|appimage|all] [/path/to/open-design.dmg]

Examples:
  bash scripts/build-packages.sh deb
  bash scripts/build-packages.sh appimage ./open-design.dmg
  bash scripts/build-packages.sh all

Notes:
  - If app_asar is missing and a DMG path is provided, setup runs automatically.
  - Output artifacts are written to: ${ROOT_DIR}/dist
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

if [[ "${TARGET}" == "-h" || "${TARGET}" == "--help" ]]; then
  print_usage
  exit 0
fi

case "${TARGET}" in
  deb) TARGET_ARGS=(--linux deb) ;;
  appimage) TARGET_ARGS=(--linux AppImage) ;;
  all) TARGET_ARGS=(--linux deb AppImage) ;;
  *)
    echo "Invalid target: ${TARGET}" >&2
    print_usage >&2
    exit 1
    ;;
esac

need_cmd node
need_cmd npm

if [[ ! -d "${APP_DIR}" || ! -f "${APP_DIR}/package.json" || ! -f "${APP_DIR}/main.cjs" ]]; then
  if [[ -n "${DMG_PATH}" ]]; then
    echo "App payload is incomplete. Running setup using: ${DMG_PATH}"
    SKIP_APP_INSTALL=1 bash "${ROOT_DIR}/scripts/setup.sh" "${DMG_PATH}"
  else
    echo "Missing app payload. Required:" >&2
    echo "  - ${APP_DIR}/package.json" >&2
    echo "  - ${APP_DIR}/main.cjs" >&2
    echo "Run setup first, or pass a DMG path as arg #2." >&2
    exit 1
  fi
fi

# Verify the native module was rebuilt for Linux (ELF), not left as Mach-O.
NODE_BIN="${APP_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
if [[ ! -f "${NODE_BIN}" ]]; then
  echo "Missing native module: ${NODE_BIN}" >&2
  echo "Run scripts/internal/build-native.sh." >&2
  exit 1
fi
if ! file "${NODE_BIN}" | grep -q "ELF"; then
  echo "Native module ${NODE_BIN} is not a Linux ELF binary." >&2
  file "${NODE_BIN}" >&2
  echo "Rebuild it with scripts/internal/build-native.sh." >&2
  exit 1
fi

if [[ ! -d "${ROOT_DIR}/node_modules" ]]; then
  echo "Installing root dependencies..."
  ( cd "${ROOT_DIR}" && npm install --include=dev )
fi

# Rebuild native modules in case the payload was extracted but not rebuilt yet.
if [[ ! -f "${APP_DIR}/.linux-native-rebuilt" ]]; then
  echo "Rebuilding native modules for Linux packaging..."
  bash "${ROOT_DIR}/scripts/internal/build-native.sh"
  touch "${APP_DIR}/.linux-native-rebuilt"
fi

echo "Building target: ${TARGET}"
(
  cd "${ROOT_DIR}"
  export CSC_IDENTITY_AUTO_DISCOVERY=false
  npx electron-builder --config electron-builder.yml --publish never "${TARGET_ARGS[@]}"
)

echo "Done. Artifacts:"
ls -1 "${ROOT_DIR}/dist"

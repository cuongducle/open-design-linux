#!/usr/bin/env bash
# Rebuild Open Design's native modules for the target Electron ABI on Linux.
#
# The macOS DMG ships a Mach-O better_sqlite3.node. On Linux we need an ELF
# .node linked against Node's N-API for the Electron version we package. We
# build it from source via @electron/rebuild so it matches whatever Electron
# release this repo pins, then copy it over the macOS artifact.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${APP_DIR:-${ROOT_DIR}/app_asar/app}"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build_native}"
NATIVE_ARCH="${NATIVE_ARCH:-${npm_config_arch:-$(node -p "process.arch")}}"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "Missing ${APP_DIR}. Run scripts/setup.sh first." >&2
  exit 1
fi

if [[ ! -d "${ROOT_DIR}/node_modules" ]]; then
  echo "Missing local node_modules. Run: npm install" >&2
  exit 1
fi

ELECTRON_VERSION="${ELECTRON_VERSION:-$(node -p "require('${ROOT_DIR}/node_modules/electron/package.json').version")}"
BETTER_SQLITE3_VERSION="$(node -p "require('${APP_DIR}/node_modules/better-sqlite3/package.json').version")"

echo "Electron:      ${ELECTRON_VERSION}"
echo "better-sqlite3: ${BETTER_SQLITE3_VERSION}"
echo "Target arch:   ${NATIVE_ARCH}"

mkdir -p "${BUILD_DIR}"
if [[ ! -f "${BUILD_DIR}/package.json" ]]; then
  ( cd "${BUILD_DIR}" && npm init -y >/dev/null )
fi

echo "Installing native build toolchain into ${BUILD_DIR}..."
(
  cd "${BUILD_DIR}"
  npm install \
    "electron@${ELECTRON_VERSION}" \
    "better-sqlite3@${BETTER_SQLITE3_VERSION}" \
    "@electron/rebuild"
)

echo "Rebuilding better-sqlite3 from source for Electron ${ELECTRON_VERSION} (${NATIVE_ARCH})..."
(
  cd "${BUILD_DIR}"
  npx electron-rebuild \
    -v "${ELECTRON_VERSION}" \
    -a "${NATIVE_ARCH}" \
    -f --build-from-source \
    -w better-sqlite3
)

echo "Copying rebuilt better_sqlite3.node into app payload..."
mkdir -p "${APP_DIR}/node_modules/better-sqlite3/build/Release"
cp -f "${BUILD_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
      "${APP_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"

# Sanity-check the artifact is a Linux ELF, not a leftover Mach-O.
if ! file "${APP_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" | grep -q "ELF"; then
  echo "Rebuilt better_sqlite3.node is not an ELF binary." >&2
  file "${APP_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" >&2
  exit 1
fi

echo "Done rebuilding native modules."

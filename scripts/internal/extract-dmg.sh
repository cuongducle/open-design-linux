#!/usr/bin/env bash
# Extract Open Design app payload from a macOS DMG into layout electron-builder
# can package for Linux.
#
# Open Design is NOT shipped as app.asar. The DMG contains:
#   Contents/Resources/app/                     <- main.cjs + prebundled/ + node_modules
#   Contents/Resources/open-design/             <- resource root (skills, design-systems, bin ...)
#   Contents/Resources/open-design-web-standalone/  <- Next.js standalone server
#   Contents/Resources/open-design-config.json  <- packaged runtime config
#   Contents/Resources/icon.icns                <- app icon
#
# We extract all four into app_asar/ (the electron-builder "app" dir). The
# pnpm-style symlinks inside open-design-web-standalone are dropped by 7z, so
# we recreate them afterwards from the .pnpm store.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${ROOT_DIR}/work_dmg"
APP_ASAR_DIR="${ROOT_DIR}/app_asar"
DMG_PATH="${1:-${ROOT_DIR}/open-design.dmg}"
APP_BUNDLE_NAME="${APP_BUNDLE_NAME:-Open Design}"
RESOURCES_REL="${RESOURCES_REL:-Contents/Resources}"

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found: ${DMG_PATH}" >&2
  exit 1
fi

print_usage() {
  cat <<EOF
Usage:
  bash scripts/internal/extract-dmg.sh [/path/to/open-design.dmg]

Notes:
  - Default DMG path: ${ROOT_DIR}/open-design.dmg
  - Output: ${APP_ASAR_DIR} (app/, open-design/, open-design-web-standalone/, open-design-config.json)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_usage
  exit 0
fi

prepare_7z_bin() {
  local src="$1"
  local staged_dir staged_bin
  if [[ "${src}" == "${ROOT_DIR}"/* ]]; then
    staged_dir="$(mktemp -d)"
    staged_bin="${staged_dir}/$(basename "${src}")"
    cp -f "${src}" "${staged_bin}"
    chmod +x "${staged_bin}"
    echo "${staged_bin}"
  else
    echo "${src}"
  fi
}

extract_archive() {
  local archive_path="$1"
  local output_dir="$2"
  local log_path="$3"
  set +e
  "${SEVEN_Z_BIN}" x -y -o"${output_dir}" "${archive_path}" >"${log_path}" 2>&1
  local rc=$?
  set -e
  return "${rc}"
}

# Resolve a 7-Zip binary that can actually read modern UDZO DMG layout.
# CRITICAL: p7zip 16.02 (shipped as `7za` via the npm `7zip-bin` package, and as
# `7z`/`7za` on older Ubuntu via p7zip-full) CANNOT read the UDZO DMG format
# Open Design ships — it exits "Can not open the file as archive". Only the
# official 7-Zip for Linux (>=23) works. Note: the Ubuntu 24.04 `7zip` package
# installs version 23.01 but exposes it as `7z`/`7za`/`7zr` WRAPPERS (38-byte
# shell scripts), NOT `7zz`. So we must test capability by version string, not
# by binary name.
#
# Candidate binaries in order, then we keep the first one whose banner reports
# 7-Zip >=23 (rejecting anything that says "p7zip Version 16").
CANDIDATES=()
[[ -x "${ROOT_DIR}/tools/7zz" ]] && CANDIDATES+=("${ROOT_DIR}/tools/7zz")
command -v 7zz >/dev/null 2>&1 && CANDIDATES+=("7zz")
command -v 7z  >/dev/null 2>&1 && CANDIDATES+=("7z")
command -v 7za >/dev/null 2>&1 && CANDIDATES+=("7za")
if [[ -d "${ROOT_DIR}/node_modules" ]]; then
  NODE_7ZA="$(node -e "try{console.log(require('7zip-bin').path7za)}catch(e){}" 2>/dev/null || true)"
  [[ -n "${NODE_7ZA}" ]] && CANDIDATES+=("${NODE_7ZA}")
fi

SEVEN_Z_BIN=""
for candidate in "${CANDIDATES[@]}"; do
  banner="$("${candidate}" 2>&1 | head -2 | tail -1 || true)"
  # Reject p7zip 16.02 outright — it cannot read UDZO DMGs.
  if printf '%s' "${banner}" | grep -qi "p7zip Version 16"; then
    echo "  skipping ${candidate}: p7zip 16.02 (cannot read UDZO DMG)" >&2
    continue
  fi
  # Accept 7-Zip for Linux (>=23) whose banner is "7-Zip (z) NN.MM ...".
  if printf '%s' "${banner}" | grep -qiE "7-Zip \(z\) [0-9]+"; then
    SEVEN_Z_BIN="${candidate}"
    echo "  selected ${candidate}: ${banner}"
    break
  fi
  # Some builds print "7-Zip [64] NN.MM" without the (z). Accept those too as
  # long as the version is >=23.
  ver="$(printf '%s' "${banner}" | grep -oE "[0-9]+\.[0-9]+" | head -1 || true)"
  if [[ -n "${ver}" ]] && [[ "${ver%%.*}" -ge 23 ]]; then
    SEVEN_Z_BIN="${candidate}"
    echo "  selected ${candidate}: ${banner}"
    break
  fi
done

if [[ -z "${SEVEN_Z_BIN}" ]]; then
  cat >&2 <<'ERR'
No capable 7-Zip binary found. The legacy p7zip 16.02 (`7z`/`7za`/`7zip-bin`)
cannot read the modern UDZO DMG layout Open Design ships. Install 7-Zip for
Linux >=23:

  Debian/Ubuntu 24.04+:  sudo apt install 7zip   (provides /usr/bin/7z wrapper)
  Other distros:         download from https://github.com/ip7z/7zip/releases
                          and place the binary at tools/7zz

ERR
  exit 1
fi
SEVEN_Z_BIN="$(prepare_7z_bin "${SEVEN_Z_BIN}")"

rm -rf "${WORK_DIR}" "${APP_ASAR_DIR}"
mkdir -p "${WORK_DIR}" "${APP_ASAR_DIR}"

echo "[1/4] Extracting DMG..."
EXTRACT_LOG="${WORK_DIR}/7z-extract.log"
EXTRACT_RC=0
extract_archive "${DMG_PATH}" "${WORK_DIR}" "${EXTRACT_LOG}" || EXTRACT_RC=$?
if [[ "${EXTRACT_RC}" -ne 0 ]]; then
  if grep -q "Dangerous link path was ignored" "${EXTRACT_LOG}"; then
    echo "7z warning: ignored unsafe symlink entries in DMG, continuing."
  elif command -v dmg2img >/dev/null 2>&1; then
    echo "Direct DMG extraction failed, retrying via dmg2img..." >&2
    IMG_PATH="${WORK_DIR}/open-design.img"
    dmg2img "${DMG_PATH}" "${IMG_PATH}" >/dev/null
    EXTRACT_RC=0
    extract_archive "${IMG_PATH}" "${WORK_DIR}" "${EXTRACT_LOG}" || EXTRACT_RC=$?
    if [[ "${EXTRACT_RC}" -ne 0 ]]; then
      cat "${EXTRACT_LOG}" >&2
      exit "${EXTRACT_RC}"
    fi
  else
    cat "${EXTRACT_LOG}" >&2
    exit "${EXTRACT_RC}"
  fi
fi

# Locate the Resources directory of the app bundle.
RESOURCES_DIR="$(find "${WORK_DIR}" -type d -path "*/${APP_BUNDLE_NAME}.app/${RESOURCES_REL}" | head -n 1 || true)"
if [[ -z "${RESOURCES_DIR}" ]]; then
  RESOURCES_DIR="$(find "${WORK_DIR}" -type d -path "*/${RESOURCES_REL}" | head -n 1 || true)"
fi
if [[ -z "${RESOURCES_DIR}" || ! -d "${RESOURCES_DIR}/app" ]]; then
  cat "${EXTRACT_LOG}" >&2 || true
  echo "Could not locate ${RESOURCES_REL}/app in extracted DMG payload." >&2
  exit 1
fi

echo "[2/4] Copying app/, open-design/, open-design-web-standalone/ ..."
cp -a "${RESOURCES_DIR}/app" "${APP_ASAR_DIR}/app"

if [[ -d "${RESOURCES_DIR}/open-design" ]]; then
  cp -a "${RESOURCES_DIR}/open-design" "${APP_ASAR_DIR}/open-design"
fi

if [[ -d "${RESOURCES_DIR}/open-design-web-standalone" ]]; then
  cp -a "${RESOURCES_DIR}/open-design-web-standalone" "${APP_ASAR_DIR}/open-design-web-standalone"
fi

if [[ -f "${RESOURCES_DIR}/open-design-config.json" ]]; then
  cp -a "${RESOURCES_DIR}/open-design-config.json" "${APP_ASAR_DIR}/open-design-config.json"
fi

if [[ -f "${RESOURCES_DIR}/icon.icns" ]]; then
  cp -a "${RESOURCES_DIR}/icon.icns" "${APP_ASAR_DIR}/icon.icns"
fi

# [3/4] Recreate pnpm symlinks dropped by 7z inside open-design-web-standalone.
# 7z refuses to write symlinks it deems "dangerous" and leaves 0-byte files in
# their place. The standalone server's node_modules uses pnpm's symlink farm, so
# any dropped link breaks require() resolution (e.g. @opentelemetry/api).
echo "[3/4] Recreating dropped pnpm symlinks in open-design-web-standalone..."
recreate_pnpm_links() {
  local nm="$1"
  local store="${nm}/.pnpm/node_modules"
  [[ -d "${store}" ]] || return 0

  while IFS= read -r -d '' empty; do
    # Only treat regular empty files as candidates (not directories).
    [[ -f "${empty}" && ! -s "${empty}" ]] || continue
    rel="${empty#${nm}/}"
    target_name="$(basename "${rel}")"
    # pnpm links live under scoped or flat dirs; resolve against the store root.
    scope_dir="$(dirname "${rel}")"
    store_target=""
    # Try same relative path under the store first.
    if [[ -e "${store}/${rel}" ]]; then
      store_target="${store}/${rel}"
    elif [[ -e "${store}/${target_name}" ]]; then
      store_target="${store}/${target_name}"
    else
      continue
    fi
    rm -f "${empty}"
    ln -sf "relative_or_abs_placeholder" "${empty}" 2>/dev/null || true
    rm -f "${empty}"
    ln -sf "${store_target}" "${empty}"
    echo "  relinked ${rel} -> ${store_target}"
  done < <(find "${nm}" -type f -size 0 ! -name ".*" -print0 2>/dev/null)
}
if [[ -d "${APP_ASAR_DIR}/open-design-web-standalone/node_modules" ]]; then
  recreate_pnpm_links "${APP_ASAR_DIR}/open-design-web-standalone/node_modules"
fi

# Write a root package.json so electron-builder sees app_asar/ as the Electron
# app dir with main -> app/main.cjs. The macOS bundle has no top-level
# package.json (it lives in Contents/Resources/app/), but electron-builder needs
# one at the app-dir root. extraMetadata in electron-builder.yml overrides
# name/productName, so this only needs main + version.
if [[ ! -f "${APP_ASAR_DIR}/package.json" ]]; then
  APP_VERSION="$(node -p "require('${APP_ASAR_DIR}/app/package.json').version" 2>/dev/null || echo "0.0.0")"
  cat > "${APP_ASAR_DIR}/package.json" <<PKGJSON
{
  "name": "open-design-linux-app",
  "private": true,
  "version": "${APP_VERSION}",
  "description": "Open Design packaged app (rebuilt for Linux)",
  "main": "app/main.cjs"
}
PKGJSON
  echo "Wrote root package.json (main -> app/main.cjs, version ${APP_VERSION})"
fi

echo "[4/4] Verifying payload..."
if [[ ! -f "${APP_ASAR_DIR}/app/package.json" ]]; then
  echo "Missing ${APP_ASAR_DIR}/app/package.json" >&2
  exit 1
fi
if [[ ! -f "${APP_ASAR_DIR}/app/main.cjs" ]]; then
  echo "Missing ${APP_ASAR_DIR}/app/main.cjs" >&2
  exit 1
fi
APP_VERSION="$(node -p "require('${APP_ASAR_DIR}/app/package.json').version" 2>/dev/null || echo "unknown")"
echo "  app version: ${APP_VERSION}"
echo "  app dir: ${APP_ASAR_DIR}/app"
[[ -d "${APP_ASAR_DIR}/open-design-web-standalone" ]] && echo "  web-standalone: present"
[[ -d "${APP_ASAR_DIR}/open-design" ]] && echo "  open-design root: present"

# Clean up the work dir to save disk in CI.
rm -rf "${WORK_DIR}"
echo "Done."

#!/usr/bin/env bash
# Read the Open Design version from a DMG's app/package.json without fully
# extracting it. Used by the upstream-check workflow to detect version bumps.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${1:-${ROOT_DIR}/open-design.dmg}"
WORK_DIR="${ROOT_DIR}/work_version_check"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_cmd node

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found: ${DMG_PATH}" >&2
  exit 1
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

# Resolve a capable 7-Zip (>=23) by version string, not by name. The Ubuntu
# 24.04 `7zip` package installs 7-Zip 23.01 but exposes it as `7z`/`7za`/`7zr`
# wrappers, NOT `7zz`; and the npm `7zip-bin` ships p7zip 16.02 which cannot
# read UDZO DMGs. See extract-dmg.sh for the full rationale.
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
  if printf '%s' "${banner}" | grep -qi "p7zip Version 16"; then continue; fi
  if printf '%s' "${banner}" | grep -qiE "7-Zip \(z\) [0-9]+"; then SEVEN_Z_BIN="${candidate}"; break; fi
  ver="$(printf '%s' "${banner}" | grep -oE "[0-9]+\.[0-9]+" | head -1 || true)"
  if [[ -n "${ver}" ]] && [[ "${ver%%.*}" -ge 23 ]]; then SEVEN_Z_BIN="${candidate}"; break; fi
done
if [[ -z "${SEVEN_Z_BIN}" ]]; then
  echo "No capable 7-Zip (>=23) found. Install the '7zip' apt package or place tools/7zz." >&2
  exit 1
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

EXTRACT_LOG="${WORK_DIR}/7z-extract.log"
EXTRACT_RC=0
set +e
"${SEVEN_Z_BIN}" x -y -o"${WORK_DIR}" "${DMG_PATH}" >"${EXTRACT_LOG}" 2>&1 || EXTRACT_RC=$?
set -e
if [[ "${EXTRACT_RC}" -ne 0 ]]; then
  if grep -q "Dangerous link path was ignored" "${EXTRACT_LOG}"; then
    : # non-fatal
  elif command -v dmg2img >/dev/null 2>&1; then
    IMG_PATH="${WORK_DIR}/open-design.img"
    dmg2img "${DMG_PATH}" "${IMG_PATH}" >/dev/null
    set +e
    "${SEVEN_Z_BIN}" x -y -o"${WORK_DIR}" "${IMG_PATH}" >"${EXTRACT_LOG}" 2>&1 || EXTRACT_RC=$?
    set -e
    if [[ "${EXTRACT_RC}" -ne 0 ]]; then
      cat "${EXTRACT_LOG}" >&2
      exit "${EXTRACT_RC}"
    fi
  else
    cat "${EXTRACT_LOG}" >&2
    exit "${EXTRACT_RC}"
  fi
fi

# Open Design stores its version at Contents/Resources/app/package.json (NOT in
# an app.asar). Locate it and print the version field.
PKG_PATH="$(find "${WORK_DIR}" -type f -path "*/Resources/app/package.json" | head -n 1 || true)"
if [[ -z "${PKG_PATH}" ]]; then
  cat "${EXTRACT_LOG}" >&2 || true
  echo "Could not find Resources/app/package.json in DMG payload." >&2
  exit 1
fi

VERSION="$(node -p "require('${PKG_PATH}').version" 2>/dev/null || true)"
rm -rf "${WORK_DIR}"

if [[ -z "${VERSION}" ]]; then
  echo "Failed to read Open Design version from app/package.json" >&2
  exit 1
fi

echo "${VERSION}"

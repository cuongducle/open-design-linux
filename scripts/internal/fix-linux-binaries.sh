#!/usr/bin/env bash
# Install Linux-native helper binaries into the extracted app payload.
#
# The macOS DMG ships macOS-only artifacts inside the app tree:
#   1. app/node_modules/@ffmpeg-installer/ only carries the darwin-x64
#      platform package (the meta package resolves the binary from a
#      per-platform optionalDependency). On Linux the daemon dies at boot
#      with "Could not find ffmpeg executable" (issue #3).
#   2. open-design/bin/vela is a macOS Mach-O binary. Since upstream 0.18.1
#      the sign-in gate shells out to vela, so the Linux package is a dead
#      end without it (issue #1). after-pack.js strips the Mach-O; we install
#      a Linux build from the @powerformer/vela-cli-linux-x64 npm package.
#
# This script is idempotent and safe to re-run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${APP_DIR:-${ROOT_DIR}/app_asar/app}"
RESOURCE_DIR="${RESOURCE_DIR:-${ROOT_DIR}/app_asar/open-design}"
NATIVE_ARCH="${NATIVE_ARCH:-$(node -p "process.arch" 2>/dev/null || echo x64)}"

FFMPEG_PKG_VERSION="${FFMPEG_PKG_VERSION:-}"   # e.g. 4.1.0; autodetected when empty
VELA_PKG_VERSION="${VELA_PKG_VERSION:-0.1.3}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    return 1
  fi
}

need_cmd node
need_cmd npm

if [[ ! -d "${APP_DIR}" ]]; then
  echo "Missing ${APP_DIR}. Run scripts/internal/extract-dmg.sh first." >&2
  exit 1
fi

if [[ "${NATIVE_ARCH}" != "x64" ]]; then
  echo "fix-linux-binaries: unsupported arch '${NATIVE_ARCH}' (only x64 has prebuilt binaries); skipping." >&2
  exit 1
fi

TMPDL="$(mktemp -d)"
trap 'rm -rf "${TMPDL}"' EXIT

npm_pack_to() {
  local spec="$1" dest="$2" filename
  # npm pack prints the tarball filename to stdout; capture it so concurrent
  # packs in the same dir can't pick up the wrong file.
  filename="$(cd "${TMPDL}" && npm pack "${spec}" --pack-destination "${dest}" --silent)"
  if [[ -z "${filename}" ]]; then
    filename="$(basename "$(ls -1t "${dest}"/*.tgz | head -n 1)")"
  fi
  printf '%s/%s' "${dest}" "${filename}"
}

# --- 1. ffmpeg (issue #3) ----------------------------------------------------
FFMPEG_META_DIR="${APP_DIR}/node_modules/@ffmpeg-installer/ffmpeg"
FFMPEG_LINUX_DIR="${APP_DIR}/node_modules/@ffmpeg-installer/linux-x64"
FFMPEG_BIN="${FFMPEG_LINUX_DIR}/ffmpeg"

ffmpeg_ok() {
  [[ -x "${FFMPEG_BIN}" ]] && file "${FFMPEG_BIN}" 2>/dev/null | grep -q "ELF"
}

if ffmpeg_ok; then
  echo "[ffmpeg] Linux binary already present, skipping."
else
  echo "[ffmpeg] Installing @ffmpeg-installer/linux-x64 for Linux..."

  if [[ -z "${FFMPEG_PKG_VERSION}" && -f "${FFMPEG_META_DIR}/package.json" ]]; then
    FFMPEG_PKG_VERSION="$(node -p "
      try {
        const p = require('${FFMPEG_META_DIR}/package.json');
        const od = p.optionalDependencies || {};
        const v = od['@ffmpeg-installer/linux-x64'] || '';
        v.replace(/^[\^~>=< ]+/, '');
      } catch (e) { '' }
    " 2>/dev/null || true)"
  fi
  if [[ -z "${FFMPEG_PKG_VERSION}" ]]; then
    FFMPEG_PKG_VERSION="$(npm view @ffmpeg-installer/linux-x64 version --silent 2>/dev/null || true)"
  fi
  if [[ -z "${FFMPEG_PKG_VERSION}" ]]; then
    echo "[ffmpeg] Could not resolve @ffmpeg-installer/linux-x64 version." >&2
    exit 1
  fi
  echo "[ffmpeg] Using @ffmpeg-installer/linux-x64@${FFMPEG_PKG_VERSION}"

  TARBALL="$(npm_pack_to "@ffmpeg-installer/linux-x64@${FFMPEG_PKG_VERSION}" "${TMPDL}")"
  rm -rf "${TMPDL}/ffmpeg-pkg" && mkdir -p "${TMPDL}/ffmpeg-pkg"
  tar -xzf "${TARBALL}" -C "${TMPDL}/ffmpeg-pkg"

  rm -rf "${FFMPEG_LINUX_DIR}"
  mkdir -p "${FFMPEG_LINUX_DIR}"
  cp -f "${TMPDL}/ffmpeg-pkg/package/ffmpeg" "${FFMPEG_BIN}"
  chmod +x "${FFMPEG_BIN}"
  # Minimal package.json so Node resolvers treat it as a real package dir.
  cat > "${FFMPEG_LINUX_DIR}/package.json" <<EOF
{
  "name": "@ffmpeg-installer/linux-x64",
  "version": "${FFMPEG_PKG_VERSION}",
  "description": "Linux FFmpeg binary used by ffmpeg-installer (installed by open-design-linux packaging)",
  "os": ["linux"],
  "cpu": ["x64"]
}
EOF

  # Drop the macOS-only platform dir: dead Mach-O weight (after-pack would
  # strip the binaries anyway, leaving an empty husk).
  rm -rf "${APP_DIR}/node_modules/@ffmpeg-installer/darwin-x64"

  if ! ffmpeg_ok; then
    echo "[ffmpeg] Installed binary failed ELF check: ${FFMPEG_BIN}" >&2
    file "${FFMPEG_BIN}" >&2 || true
    exit 1
  fi
  echo "[ffmpeg] OK: ${FFMPEG_BIN}"
fi

# --- 2. vela CLI (issue #1) --------------------------------------------------
# The app shells out to the vela binary for sign-in (mandatory since 0.18.1).
# Expected location (mirrors the DMG layout): <resources>/open-design/bin/vela.
VELA_DIR="${RESOURCE_DIR}/bin"
VELA_BIN="${VELA_DIR}/vela"

vela_ok() {
  [[ -x "${VELA_BIN}" ]] && file "${VELA_BIN}" 2>/dev/null | grep -q "ELF"
}

if vela_ok; then
  echo "[vela] Linux binary already present, skipping."
else
  echo "[vela] Installing @powerformer/vela-cli-linux-x64@${VELA_PKG_VERSION}..."

  if [[ ! -d "${RESOURCE_DIR}" ]]; then
    echo "[vela] Resource dir missing: ${RESOURCE_DIR} (DMG had no open-design/ root?)" >&2
    exit 1
  fi

  TARBALL="$(npm_pack_to "@powerformer/vela-cli-linux-x64@${VELA_PKG_VERSION}" "${TMPDL}")"
  rm -rf "${TMPDL}/vela-pkg" && mkdir -p "${TMPDL}/vela-pkg"
  tar -xzf "${TARBALL}" -C "${TMPDL}/vela-pkg"
  SRC_BIN="${TMPDL}/vela-pkg/package/bin/vela"
  if [[ ! -f "${SRC_BIN}" ]]; then
    echo "[vela] Unexpected tarball layout, no package/bin/vela" >&2
    tar -tzf "${TARBALL}" | head >&2
    exit 1
  fi

  mkdir -p "${VELA_DIR}"
  cp -f "${SRC_BIN}" "${VELA_BIN}"
  chmod +x "${VELA_BIN}"

  if ! vela_ok; then
    echo "[vela] Installed binary failed ELF check: ${VELA_BIN}" >&2
    file "${VELA_BIN}" >&2 || true
    exit 1
  fi
  echo "[vela] OK: ${VELA_BIN}"
fi

# --- 3. Drop editor backup leftovers (issue #3 follow-up) --------------------
# The DMG payload was observed to contain development leftovers (index.js~,
# download.sh~). They are dead weight and a sign the tree was not built clean.
echo "[cleanup] Removing editor backup files (*~) from app/node_modules..."
DELETED="$(find "${APP_DIR}/node_modules" -type f -name '*~' -print -delete 2>/dev/null | wc -l | tr -d ' ')"
echo "[cleanup] Removed ${DELETED} backup file(s)."

echo "Done fixing Linux binaries."

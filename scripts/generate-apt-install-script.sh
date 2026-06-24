#!/usr/bin/env bash
# Generate a one-line install.sh that adds the flat APT repo and installs Open
# Design. Mirrors the codex-linux convenience installer.
set -euo pipefail

OWNER="${1:-}"
REPO="${2:-}"
OUT_DIR="${3:-}"
PACKAGE_NAME="${PACKAGE_NAME:-open-design}"

if [[ -z "${OWNER}" || -z "${REPO}" || -z "${OUT_DIR}" ]]; then
  echo "Usage: bash scripts/generate-apt-install-script.sh <owner> <repo> <out_dir>" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
INSTALL_SCRIPT="${OUT_DIR}/install.sh"

cat > "${INSTALL_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${EUID}" -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

SOURCE_FILE="/etc/apt/sources.list.d/${PACKAGE_NAME}.list"
REPO_LINE="deb [trusted=yes] https://github.com/${OWNER}/${REPO}/releases/latest/download/ ./"

echo "\${REPO_LINE}" > "\${SOURCE_FILE}"
apt update
apt install -y ${PACKAGE_NAME}
echo "Installed: ${PACKAGE_NAME}"
EOF

chmod +x "${INSTALL_SCRIPT}"
echo "Generated ${INSTALL_SCRIPT}"

#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

SOURCE_FILE="/etc/apt/sources.list.d/open-design.list"
REPO_LINE="deb [trusted=yes] https://github.com/cuongducle/open-design-linux/releases/latest/download/ ./"

echo "${REPO_LINE}" > "${SOURCE_FILE}"
apt update
apt install -y open-design
echo "Installed: open-design"

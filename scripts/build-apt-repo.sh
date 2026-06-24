#!/usr/bin/env bash
# Build an APT repository from the built .deb files. Supports a "flat" layout
# (everything in one directory, suitable for GitHub Releases assets) and a
# classic pool/dists layout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${1:-${ROOT_DIR}/apt-public}"
PACKAGE_NAME="${PACKAGE_NAME:-open-design}"
FLAT_REPO="${FLAT_REPO:-0}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_cmd dpkg-scanpackages
need_cmd gzip
need_cmd sha256sum
need_cmd md5sum
need_cmd stat

mkdir -p "${REPO_DIR}"

shopt -s nullglob
deb_files=("${REPO_DIR}"/*.deb)
if [[ "${#deb_files[@]}" -eq 0 ]]; then
  echo "No .deb files found in ${REPO_DIR}" >&2
  exit 1
fi

generate_release_file() {
  local release_path="$1"
  local packages_file="$2"
  local packages_rel="$3"

  local packages_gz_file="${packages_file}.gz"
  local packages_gz_rel="${packages_rel}.gz"
  local packages_size packages_gz_size
  local packages_md5 packages_gz_md5
  local packages_sha256 packages_gz_sha256

  packages_size="$(stat -c%s "${packages_file}")"
  packages_gz_size="$(stat -c%s "${packages_gz_file}")"
  packages_md5="$(md5sum "${packages_file}" | awk '{print $1}')"
  packages_gz_md5="$(md5sum "${packages_gz_file}" | awk '{print $1}')"
  packages_sha256="$(sha256sum "${packages_file}" | awk '{print $1}')"
  packages_gz_sha256="$(sha256sum "${packages_gz_file}" | awk '{print $1}')"

  {
    echo "Origin: ${PACKAGE_NAME}"
    echo "Label: ${PACKAGE_NAME}"
    echo "Suite: stable"
    echo "Codename: stable"
    echo "Date: $(LC_ALL=C date -Ru)"
    echo "Architectures: amd64"
    echo "Components: main"
    echo "Description: ${PACKAGE_NAME} APT repository"
    echo "MD5Sum:"
    echo " ${packages_md5} ${packages_size} ${packages_rel}"
    echo " ${packages_gz_md5} ${packages_gz_size} ${packages_gz_rel}"
    echo "SHA256:"
    echo " ${packages_sha256} ${packages_size} ${packages_rel}"
    echo " ${packages_gz_sha256} ${packages_gz_size} ${packages_gz_rel}"
  } > "${release_path}"
}

if [[ "${FLAT_REPO}" == "1" ]]; then
  PACKAGES_FILE="${REPO_DIR}/Packages"
  PACKAGES_GZ_FILE="${PACKAGES_FILE}.gz"

  (
    cd "${REPO_DIR}"
    dpkg-scanpackages --multiversion . /dev/null > "${PACKAGES_FILE#${REPO_DIR}/}"
  )

  sed -i 's|^Filename: \./|Filename: |' "${PACKAGES_FILE}"
  gzip -9 -c "${PACKAGES_FILE}" > "${PACKAGES_GZ_FILE}"

  generate_release_file "${REPO_DIR}/Release" "${PACKAGES_FILE}" "Packages"

  gzip -9 -c /dev/null > "${REPO_DIR}/Translation-en.gz"

  rm -f "${REPO_DIR}"/*.deb

  echo "Flat APT repository generated at: ${REPO_DIR}"
  echo "Package index: ${PACKAGES_FILE}"
else
  mkdir -p "${REPO_DIR}/pool/main/o/${PACKAGE_NAME}"
  mkdir -p "${REPO_DIR}/dists/stable/main/binary-amd64"

  for deb in "${deb_files[@]}"; do
    cp -f "${deb}" "${REPO_DIR}/pool/main/o/${PACKAGE_NAME}/"
  done

  PACKAGES_FILE="${REPO_DIR}/dists/stable/main/binary-amd64/Packages"
  PACKAGES_GZ_FILE="${PACKAGES_FILE}.gz"
  RELEASE_FILE="${REPO_DIR}/dists/stable/Release"

  (
    cd "${REPO_DIR}"
    dpkg-scanpackages --multiversion pool /dev/null > "${PACKAGES_FILE#${REPO_DIR}/}"
  )

  gzip -9 -c "${PACKAGES_FILE}" > "${PACKAGES_GZ_FILE}"

  generate_release_file "${RELEASE_FILE}" "${PACKAGES_FILE}" \
    "main/binary-amd64/Packages"

  if [[ -n "${RELEASES_BASE_URL:-}" ]]; then
    rm -f "${REPO_DIR}/pool/main/o/${PACKAGE_NAME}"/*.deb
    rm -f "${REPO_DIR}"/*.deb
  fi

  echo "APT repository generated at: ${REPO_DIR}"
  echo "Package index: ${PACKAGES_FILE}"
  echo "Release file: ${RELEASE_FILE}"
fi

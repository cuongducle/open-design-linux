#!/usr/bin/env bash
# Smoke-verify the packaged Open Design: launch it headless and watch the log
# for bootstrap/crash errors. Used in CI after the build step.
set -euo pipefail

APP_CMD="${1:-open-design}"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-35}"
LOG_FILE="${SMOKE_LOG_FILE:-/tmp/open-design-smoke.log}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

info() {
  echo "== $* =="
}

info "Resolving commands"
command -v "${APP_CMD}" >/dev/null 2>&1 || fail "${APP_CMD} is not on PATH"
APP_PATH="$(command -v "${APP_CMD}")"
APP_REALPATH="$(readlink -f "${APP_PATH}" 2>/dev/null || printf '%s' "${APP_PATH}")"
echo "app_path=${APP_PATH}"
echo "app_realpath=${APP_REALPATH}"

info "Checking desktop entries"
shopt -s nullglob
for desktop_file in /usr/share/applications/*open-design* ~/.local/share/applications/*open-design*; do
  [[ -f "${desktop_file}" ]] || continue
  echo "--- ${desktop_file}"
  grep -E '^(Name|Exec|StartupWMClass)=' "${desktop_file}" || true
done

info "Launching smoke test (headless, ${TIMEOUT_SECONDS}s)"
rm -f "${LOG_FILE}"
# Run under a virtual framebuffer when available so the Electron renderer can
# initialise. xvfb-run is best-effort; if it is absent we still launch and rely
# on the timeout to terminate.
RUNNER=()
if command -v xvfb-run >/dev/null 2>&1; then
  RUNNER=(xvfb-run -a)
fi

set +e
timeout "${TIMEOUT_SECONDS}s" env ELECTRON_ENABLE_LOGGING=1 \
  "${RUNNER[@]}" \
  "${APP_CMD}" --no-sandbox --disable-gpu --disable-features=Vulkan \
  >"${LOG_FILE}" 2>&1
status=$?
set -e

echo "exit_status=${status}"
echo "log_file=${LOG_FILE}"
tail -120 "${LOG_FILE}" || true

# Fatal bootstrap errors we never want to see.
if grep -Eiq \
  'Cannot find module|ERR_MODULE_NOT_FOUND|ENOENT|EACCES|Trace/breakpoint trap|Segmentation fault|better_sqlite3\.node was compiled against a different Node|was compiled against a different Node' \
  "${LOG_FILE}"; then
  fail "smoke log contains bootstrap/crash error"
fi

# 124 = timeout (expected for a long-running desktop app); 0 = clean quit.
if [[ "${status}" -ne 0 && "${status}" -ne 124 ]]; then
  fail "app exited before smoke timeout"
fi

info "PASS"

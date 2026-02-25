#!/usr/bin/env bash
#
# This script performs an environment health check for LimitLens runtime readiness.
# It verifies toolchain, local source paths, and optional provider binaries so users
# can diagnose setup issues before expecting live usage metrics.
#
# It exists separately because operational diagnostics are a support concern that
# should stay outside product runtime code.
#
# This script talks to the local shell environment, provider directories, and provider
# binaries (`codex`, `antigravity`) when present.

set -euo pipefail

print_check() {
  local label="$1"
  local status="$2"
  local detail="$3"
  printf "%-28s %-8s %s\n" "${label}" "${status}" "${detail}"
}

echo "LimitLens Doctor"
echo "============="

if command -v swift >/dev/null 2>&1; then
  print_check "Swift toolchain" "OK" "$(swift --version | head -n1)"
else
  print_check "Swift toolchain" "FAIL" "swift not found"
fi

if command -v codex >/dev/null 2>&1; then
  print_check "Codex CLI" "OK" "$(codex --version | head -n1)"
else
  print_check "Codex CLI" "WARN" "codex binary not found"
fi

if command -v antigravity >/dev/null 2>&1; then
  print_check "Antigravity CLI" "OK" "$(antigravity --version | head -n1)"
else
  print_check "Antigravity CLI" "WARN" "antigravity binary not found"
fi

for path in "${HOME}/.codex/sessions" "${HOME}/.claude/projects" "${HOME}/Library/Application Support/Antigravity/logs"; do
  if [[ -d "${path}" ]]; then
    print_check "Path: ${path}" "OK" "found"
  else
    print_check "Path: ${path}" "WARN" "missing"
  fi
done

if [[ -f "${HOME}/Library/LaunchAgents/com.limitlens.menubar.plist" ]]; then
  print_check "Launch agent" "OK" "configured"
else
  print_check "Launch agent" "INFO" "not configured"
fi

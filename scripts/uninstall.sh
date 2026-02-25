#!/usr/bin/env bash
#
# This script removes local LimitLens installations created by scripts/install.sh.
# It cleans app bundle artifacts, CLI binaries, and launch-agent registration so
# reinstalling starts from a predictable baseline.
#
# It exists as a separate script because teardown should be deterministic and
# explicit rather than relying on manual filesystem cleanup.
#
# This script talks to launchctl for agent removal and the local filesystem for
# binary and app bundle deletion.

set -euo pipefail

CLI_INSTALL_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/Applications/LimitLens.app"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/com.limitlens.menubar.plist"
USER_ID="$(id -u)"

echo "[uninstall] Removing launch agent registration if present..."
launchctl bootout "gui/${USER_ID}" "${LAUNCH_AGENT}" >/dev/null 2>&1 || true
rm -f "${LAUNCH_AGENT}"

echo "[uninstall] Removing CLI binaries..."
rm -f "${CLI_INSTALL_DIR}/limitlens" "${CLI_INSTALL_DIR}/limitlens-core-tests"

echo "[uninstall] Removing app bundle..."
rm -rf "${APP_DIR}"

echo "[uninstall] Completed."

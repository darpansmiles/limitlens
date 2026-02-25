#!/usr/bin/env bash
#
# This script installs LimitLens locally on macOS in a developer-friendly way.
# It builds release binaries, installs CLI tools under ~/.local/bin, and creates
# a runnable app bundle at ~/Applications/LimitLens.app for stable launch-at-login paths.
#
# It exists as a separate script because installation concerns should not be baked
# into runtime code. Keeping install logic here makes distribution workflows explicit
# and repeatable for contributors and operators.
#
# This script talks to SwiftPM for builds, the local filesystem for app/CLI placement,
# and macOS `open` for optional first-launch behavior.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_INSTALL_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/Applications/LimitLens.app"
APP_CONTENTS_DIR="${APP_DIR}/Contents"
APP_MACOS_DIR="${APP_CONTENTS_DIR}/MacOS"
APP_RESOURCES_DIR="${APP_CONTENTS_DIR}/Resources"

mkdir -p "${CLI_INSTALL_DIR}"
mkdir -p "${APP_MACOS_DIR}"
mkdir -p "${APP_RESOURCES_DIR}"

echo "[install] Building release binaries..."
(
  cd "${ROOT_DIR}"
  swift build -c release --product limitlens
  swift build -c release --product limitlens-core-tests
  swift build -c release --product LimitLensMenuBar
)

echo "[install] Installing CLI binaries to ${CLI_INSTALL_DIR}"
cp "${ROOT_DIR}/.build/release/limitlens" "${CLI_INSTALL_DIR}/limitlens"
cp "${ROOT_DIR}/.build/release/limitlens-core-tests" "${CLI_INSTALL_DIR}/limitlens-core-tests"
chmod +x "${CLI_INSTALL_DIR}/limitlens" "${CLI_INSTALL_DIR}/limitlens-core-tests"

echo "[install] Creating app bundle at ${APP_DIR}"
cp "${ROOT_DIR}/.build/release/LimitLensMenuBar" "${APP_MACOS_DIR}/LimitLensMenuBar"
chmod +x "${APP_MACOS_DIR}/LimitLensMenuBar"

cat > "${APP_CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>LimitLens</string>
  <key>CFBundleExecutable</key>
  <string>LimitLensMenuBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.limitlens.menubar</string>
  <key>CFBundleName</key>
  <string>LimitLens</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.4.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "[install] Installed successfully."
echo "[install] CLI: ${CLI_INSTALL_DIR}/limitlens"
echo "[install] App: ${APP_DIR}"

if [[ ":${PATH}:" != *":${CLI_INSTALL_DIR}:"* ]]; then
  echo "[install] NOTE: ${CLI_INSTALL_DIR} is not in PATH. Add this to ~/.zshrc:"
  echo "export PATH=\"${CLI_INSTALL_DIR}:\$PATH\""
fi

echo "[install] Launching LimitLens app once to initialize permissions..."
open "${APP_DIR}" || true

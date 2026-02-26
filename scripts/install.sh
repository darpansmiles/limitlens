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
BUILD_ROOT="${ROOT_DIR}/.build-universal"
ARM_BUILD_DIR="${BUILD_ROOT}/arm64"
X86_BUILD_DIR="${BUILD_ROOT}/x86_64"
UNIVERSAL_DIR="${BUILD_ROOT}/universal"
PRODUCTS=("limitlens" "limitlens-core-tests" "LimitLensMenuBar")

mkdir -p "${CLI_INSTALL_DIR}"
mkdir -p "${APP_MACOS_DIR}"
mkdir -p "${APP_RESOURCES_DIR}"
mkdir -p "${UNIVERSAL_DIR}"

if ! command -v lipo >/dev/null 2>&1; then
  echo "[install] ERROR: lipo is required to create universal binaries." >&2
  exit 1
fi

build_for_arch() {
  local arch="$1"
  local scratch_path="$2"
  echo "[install] Building release binaries for ${arch}..."
  (
    cd "${ROOT_DIR}"
    swift build -c release --arch "${arch}" --scratch-path "${scratch_path}" --product limitlens
    swift build -c release --arch "${arch}" --scratch-path "${scratch_path}" --product limitlens-core-tests
    swift build -c release --arch "${arch}" --scratch-path "${scratch_path}" --product LimitLensMenuBar
  )
}

create_universal_binary() {
  local name="$1"
  local arm_binary="${ARM_BUILD_DIR}/release/${name}"
  local x86_binary="${X86_BUILD_DIR}/release/${name}"
  local universal_binary="${UNIVERSAL_DIR}/${name}"

  # We ship one processor-agnostic executable by merging both architectures.
  lipo -create "${arm_binary}" "${x86_binary}" -output "${universal_binary}"
  chmod +x "${universal_binary}"
}

build_for_arch "arm64" "${ARM_BUILD_DIR}"
build_for_arch "x86_64" "${X86_BUILD_DIR}"

for product in "${PRODUCTS[@]}"; do
  create_universal_binary "${product}"
done

echo "[install] Installing CLI binaries to ${CLI_INSTALL_DIR}"
cp "${UNIVERSAL_DIR}/limitlens" "${CLI_INSTALL_DIR}/limitlens"
cp "${UNIVERSAL_DIR}/limitlens-core-tests" "${CLI_INSTALL_DIR}/limitlens-core-tests"
chmod +x "${CLI_INSTALL_DIR}/limitlens" "${CLI_INSTALL_DIR}/limitlens-core-tests"

echo "[install] Creating app bundle at ${APP_DIR}"
cp "${UNIVERSAL_DIR}/LimitLensMenuBar" "${APP_MACOS_DIR}/LimitLensMenuBar"
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

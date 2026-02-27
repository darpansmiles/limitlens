#!/usr/bin/env bash
#
# This script builds a distributable LimitLens DMG for macOS release distribution.
# It creates a universal menu bar executable, assembles an app bundle, optionally
# signs/notarizes it, and packages the result with an Applications shortcut.
#
# It exists as a separate script because release packaging is an operational concern
# that should be reproducible without manual Finder steps.
#
# This script talks to SwiftPM for dual-arch builds, codesign/notarytool for trust
# chain integration, and hdiutil/osascript for DMG assembly and presentation.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/dist"
BUILD_ROOT="${ROOT_DIR}/.build-dmg"
ARM_BUILD_DIR="${BUILD_ROOT}/arm64"
X86_BUILD_DIR="${BUILD_ROOT}/x86_64"
UNIVERSAL_DIR="${BUILD_ROOT}/universal"
APP_DIR="${BUILD_ROOT}/LimitLens.app"
APP_CONTENTS_DIR="${APP_DIR}/Contents"
APP_MACOS_DIR="${APP_CONTENTS_DIR}/MacOS"
APP_RESOURCES_DIR="${APP_CONTENTS_DIR}/Resources"
DMG_STAGING_DIR="${BUILD_ROOT}/dmg-staging"
DMG_VOLUME_NAME="LimitLens"
SIGN_IDENTITY=""
UNSIGNED=0
NOTARIZE_PROFILE=""
VERSION=""

usage() {
  cat <<'EOF'
Usage: bash scripts/build-dmg.sh [options]

Options:
  --version <semver>             Version for DMG filename and app plist.
  --output-dir <path>            Directory for final DMG output. Default: ./dist
  --sign-identity <identity>     Codesign identity (Developer ID Application ...).
  --notarize-profile <profile>   notarytool keychain profile name for notarization.
  --unsigned                     Skip signing/notarization steps.
  -h, --help                     Show this help.

Examples:
  bash scripts/build-dmg.sh --version 0.5.0 --unsigned
  bash scripts/build-dmg.sh --sign-identity "Developer ID Application: Example, Inc." --notarize-profile limitlens-notary
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      shift 2
      ;;
    --notarize-profile)
      NOTARIZE_PROFILE="${2:-}"
      shift 2
      ;;
    --unsigned)
      UNSIGNED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[dmg] ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  VERSION="$(node -p "require('${ROOT_DIR}/package.json').version")"
fi

mkdir -p "${OUTPUT_DIR}"
mkdir -p "${APP_MACOS_DIR}" "${APP_RESOURCES_DIR}" "${UNIVERSAL_DIR}" "${DMG_STAGING_DIR}"

if ! command -v lipo >/dev/null 2>&1; then
  echo "[dmg] ERROR: lipo is required to build universal binaries." >&2
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "[dmg] ERROR: hdiutil is required to build DMG files." >&2
  exit 1
fi

build_for_arch() {
  local arch="$1"
  local scratch_path="$2"
  echo "[dmg] Building LimitLensMenuBar for ${arch}..."
  (
    cd "${ROOT_DIR}"
    swift build -c release --arch "${arch}" --scratch-path "${scratch_path}" --product LimitLensMenuBar
  )
}

build_for_arch "arm64" "${ARM_BUILD_DIR}"
build_for_arch "x86_64" "${X86_BUILD_DIR}"

echo "[dmg] Creating universal executable..."
lipo -create \
  "${ARM_BUILD_DIR}/release/LimitLensMenuBar" \
  "${X86_BUILD_DIR}/release/LimitLensMenuBar" \
  -output "${UNIVERSAL_DIR}/LimitLensMenuBar"
chmod +x "${UNIVERSAL_DIR}/LimitLensMenuBar"

echo "[dmg] Assembling app bundle..."
cp "${UNIVERSAL_DIR}/LimitLensMenuBar" "${APP_MACOS_DIR}/LimitLensMenuBar"
chmod +x "${APP_MACOS_DIR}/LimitLensMenuBar"

cat > "${APP_CONTENTS_DIR}/Info.plist" <<PLIST
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
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if [[ "${UNSIGNED}" -eq 0 ]]; then
  if [[ -z "${SIGN_IDENTITY}" ]]; then
    # Ad-hoc signing keeps local distribution friction low until Developer ID is configured.
    SIGN_IDENTITY="-"
  fi

  echo "[dmg] Signing app bundle with identity: ${SIGN_IDENTITY}"
  if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign --force --deep --sign "-" "${APP_DIR}"
  else
    codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_DIR}"
  fi
  codesign --verify --deep --strict "${APP_DIR}"
else
  echo "[dmg] Skipping signing (--unsigned)."
fi

echo "[dmg] Preparing DMG staging directory..."
rm -rf "${DMG_STAGING_DIR}"
mkdir -p "${DMG_STAGING_DIR}"
cp -R "${APP_DIR}" "${DMG_STAGING_DIR}/LimitLens.app"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

if [[ -f "${ROOT_DIR}/docs/images/dmg-background.png" ]]; then
  mkdir -p "${DMG_STAGING_DIR}/.background"
  cp "${ROOT_DIR}/docs/images/dmg-background.png" "${DMG_STAGING_DIR}/.background/background.png"
fi

TMP_DMG="${BUILD_ROOT}/LimitLens-${VERSION}-rw.dmg"
FINAL_DMG="${OUTPUT_DIR}/LimitLens-${VERSION}.dmg"
rm -f "${TMP_DMG}" "${FINAL_DMG}"

echo "[dmg] Creating writable DMG image..."
hdiutil create \
  -volname "${DMG_VOLUME_NAME}" \
  -srcfolder "${DMG_STAGING_DIR}" \
  -fs HFS+ \
  -format UDRW \
  "${TMP_DMG}"

MOUNT_DIR="${BUILD_ROOT}/mount"
mkdir -p "${MOUNT_DIR}"
hdiutil attach "${TMP_DMG}" -mountpoint "${MOUNT_DIR}" -noautoopen >/dev/null

if [[ -f "${MOUNT_DIR}/.background/background.png" ]] && command -v osascript >/dev/null 2>&1; then
  # Finder layout is best-effort; script may fail in headless environments.
  osascript <<OSA >/dev/null 2>&1 || true
tell application "Finder"
  tell disk "${DMG_VOLUME_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {160, 120, 860, 560}
    set icon size of icon view options of container window to 120
    set arrangement of icon view options of container window to not arranged
    set background picture of icon view options of container window to file ".background:background.png"
    set position of item "LimitLens.app" of container window to {210, 260}
    set position of item "Applications" of container window to {500, 260}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
OSA
fi

hdiutil detach "${MOUNT_DIR}" >/dev/null

echo "[dmg] Creating compressed DMG..."
hdiutil convert "${TMP_DMG}" -format UDZO -imagekey zlib-level=9 -o "${FINAL_DMG}" >/dev/null

if [[ "${UNSIGNED}" -eq 0 ]] && [[ -n "${NOTARIZE_PROFILE}" ]]; then
  echo "[dmg] Submitting DMG for notarization using profile ${NOTARIZE_PROFILE}..."
  xcrun notarytool submit "${FINAL_DMG}" --keychain-profile "${NOTARIZE_PROFILE}" --wait
  echo "[dmg] Stapling notarization ticket..."
  xcrun stapler staple "${FINAL_DMG}"
fi

echo "[dmg] Built ${FINAL_DMG}"

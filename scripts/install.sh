#!/usr/bin/env bash
#
# This script installs LimitLens locally on macOS with distribution-grade behavior.
# It builds universal binaries, installs CLI tools, assembles the app bundle, and
# optionally signs/notarizes artifacts so Gatekeeper workflows are covered.
#
# It exists as a separate script because install/distribution policy should be explicit
# and reproducible rather than embedded inside runtime code.
#
# This script talks to SwiftPM for builds, codesign/notarytool for trust chain actions,
# and the filesystem for local CLI/app placement.

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
SIGN_IDENTITY=""
UNSIGNED=0
NOTARIZE_PROFILE=""
SKIP_LAUNCH=0
VERSION=""

usage() {
  cat <<'USAGE'
Usage: bash scripts/install.sh [options]

Options:
  --version <semver>             Set CFBundle version for installed app.
  --sign-identity <identity>     Codesign identity (Developer ID Application ...).
  --notarize-profile <profile>   notarytool keychain profile name for notarization.
  --unsigned                     Skip signing/notarization steps.
  --skip-launch                  Do not open the app after install.
  -h, --help                     Show this help.

Examples:
  bash scripts/install.sh --unsigned
  bash scripts/install.sh --sign-identity "Developer ID Application: Example, Inc." --notarize-profile limitlens-notary
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
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
    --skip-launch)
      SKIP_LAUNCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[install] ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  VERSION="$(node -p "require('${ROOT_DIR}/package.json').version")"
fi

mkdir -p "${CLI_INSTALL_DIR}" "${APP_MACOS_DIR}" "${APP_RESOURCES_DIR}" "${UNIVERSAL_DIR}"

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

sign_binary_if_needed() {
  local target="$1"

  if [[ "${UNSIGNED}" -eq 1 ]]; then
    return
  fi

  if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY="-"
  fi

  if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign --force --sign "-" "${target}"
  else
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${target}"
  fi
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

if [[ "${UNSIGNED}" -eq 0 ]]; then
  echo "[install] Signing installed CLI binaries..."
  sign_binary_if_needed "${CLI_INSTALL_DIR}/limitlens"
  sign_binary_if_needed "${CLI_INSTALL_DIR}/limitlens-core-tests"
fi

echo "[install] Creating app bundle at ${APP_DIR}"
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
  echo "[install] Signing app bundle..."
  if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY="-"
  fi

  if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign --force --deep --sign "-" "${APP_DIR}"
  else
    codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_DIR}"
  fi

  codesign --verify --deep --strict "${APP_DIR}"

  if [[ -n "${NOTARIZE_PROFILE}" ]]; then
    if [[ "${SIGN_IDENTITY}" == "-" ]]; then
      echo "[install] ERROR: notarization requires a Developer ID identity, not ad-hoc signing." >&2
      exit 1
    fi

    ZIP_PATH="${BUILD_ROOT}/LimitLens-install.zip"
    echo "[install] Notarizing app bundle via keychain profile ${NOTARIZE_PROFILE}..."
    ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"
    xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARIZE_PROFILE}" --wait
    xcrun stapler staple "${APP_DIR}"
  fi
else
  echo "[install] Signing skipped (--unsigned)."
fi

echo "[install] Installed successfully."
echo "[install] CLI: ${CLI_INSTALL_DIR}/limitlens"
echo "[install] App: ${APP_DIR}"

if [[ ":${PATH}:" != *":${CLI_INSTALL_DIR}:"* ]]; then
  echo "[install] NOTE: ${CLI_INSTALL_DIR} is not in PATH. Add this to ~/.zshrc:"
  echo "export PATH=\"${CLI_INSTALL_DIR}:\$PATH\""
fi

if [[ "${SKIP_LAUNCH}" -eq 0 ]]; then
  echo "[install] Launching LimitLens app once to initialize permissions..."
  open "${APP_DIR}" || true
fi

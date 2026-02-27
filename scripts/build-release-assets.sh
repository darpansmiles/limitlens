#!/usr/bin/env bash
#
# This script builds release artifacts consumed by GitHub Releases and Homebrew.
# It outputs a universal CLI tarball and a versioned DMG in `dist/`.
#
# It exists as a separate script to keep release artifact creation deterministic.
#
# This script talks to SwiftPM, lipo, tar, and `scripts/build-dmg.sh`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_ROOT="${ROOT_DIR}/.build-release"
ARM_BUILD_DIR="${BUILD_ROOT}/arm64"
X86_BUILD_DIR="${BUILD_ROOT}/x86_64"
UNIVERSAL_DIR="${BUILD_ROOT}/universal"
VERSION=""
UNSIGNED=0
SIGN_IDENTITY=""
NOTARIZE_PROFILE=""

usage() {
  cat <<'USAGE'
Usage: bash scripts/build-release-assets.sh [options]

Options:
  --version <semver>             Release version. Defaults to package.json version.
  --unsigned                     Build unsigned artifacts.
  --sign-identity <identity>     Codesign identity for DMG/app signing.
  --notarize-profile <profile>   notarytool keychain profile for notarization.
  -h, --help                     Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --unsigned)
      UNSIGNED=1
      shift
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      shift 2
      ;;
    --notarize-profile)
      NOTARIZE_PROFILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release] ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  VERSION="$(node -p "require('${ROOT_DIR}/package.json').version")"
fi

mkdir -p "${DIST_DIR}" "${UNIVERSAL_DIR}"

build_cli_for_arch() {
  local arch="$1"
  local scratch_path="$2"
  echo "[release] Building CLI for ${arch}..."
  (
    cd "${ROOT_DIR}"
    swift build -c release --arch "${arch}" --scratch-path "${scratch_path}" --product limitlens
  )
}

build_cli_for_arch "arm64" "${ARM_BUILD_DIR}"
build_cli_for_arch "x86_64" "${X86_BUILD_DIR}"

echo "[release] Creating universal CLI binary..."
lipo -create \
  "${ARM_BUILD_DIR}/release/limitlens" \
  "${X86_BUILD_DIR}/release/limitlens" \
  -output "${UNIVERSAL_DIR}/limitlens"
chmod +x "${UNIVERSAL_DIR}/limitlens"

CLI_TARBALL="${DIST_DIR}/limitlens-${VERSION}-universal.tar.gz"
rm -f "${CLI_TARBALL}"

echo "[release] Packaging CLI tarball ${CLI_TARBALL}..."
(
  cd "${UNIVERSAL_DIR}"
  tar -czf "${CLI_TARBALL}" limitlens
)

DMG_ARGS=(--version "${VERSION}")
if [[ "${UNSIGNED}" -eq 1 ]]; then
  DMG_ARGS+=(--unsigned)
fi
if [[ -n "${SIGN_IDENTITY}" ]]; then
  DMG_ARGS+=(--sign-identity "${SIGN_IDENTITY}")
fi
if [[ -n "${NOTARIZE_PROFILE}" ]]; then
  DMG_ARGS+=(--notarize-profile "${NOTARIZE_PROFILE}")
fi

bash "${ROOT_DIR}/scripts/build-dmg.sh" "${DMG_ARGS[@]}"

echo "[release] Artifacts ready in ${DIST_DIR}"
ls -lh "${DIST_DIR}" | sed 's/^/[release] /'

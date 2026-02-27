#!/usr/bin/env bash
#
# This script creates a GitHub release with standard changelog sections and uploads
# local artifacts.
#
# It exists as a separate script to make release publication consistent and auditable.
#
# This script talks to git tags and `gh release` APIs.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
NOTES_FILE=""
TARGET="main"
DRAFT=0
PRERELEASE=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/create-release.sh --version <semver> --notes-file <path> [options]

Options:
  --target <branch-or-sha>       Target git ref for tag. Default: main
  --draft                        Create release as draft.
  --prerelease                   Mark as prerelease.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --draft)
      DRAFT=1
      shift
      ;;
    --prerelease)
      PRERELEASE=1
      shift
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

if [[ -z "${VERSION}" || -z "${NOTES_FILE}" ]]; then
  usage
  exit 1
fi

if [[ ! -f "${NOTES_FILE}" ]]; then
  echo "[release] ERROR: notes file not found: ${NOTES_FILE}" >&2
  exit 1
fi

TAG="v${VERSION}"
CLI_TARBALL="${ROOT_DIR}/dist/limitlens-${VERSION}-universal.tar.gz"
DMG_FILE="${ROOT_DIR}/dist/LimitLens-${VERSION}.dmg"

if [[ ! -f "${CLI_TARBALL}" || ! -f "${DMG_FILE}" ]]; then
  echo "[release] ERROR: expected artifacts missing in dist/." >&2
  echo "[release] Run: bash scripts/build-release-assets.sh --version ${VERSION}" >&2
  exit 1
fi

FLAGS=()
if [[ "${DRAFT}" -eq 1 ]]; then
  FLAGS+=(--draft)
fi
if [[ "${PRERELEASE}" -eq 1 ]]; then
  FLAGS+=(--prerelease)
fi

if [[ ${#FLAGS[@]} -gt 0 ]]; then
  gh release create "${TAG}" \
    --target "${TARGET}" \
    --title "LimitLens ${VERSION}" \
    --notes-file "${NOTES_FILE}" \
    "${CLI_TARBALL}" \
    "${DMG_FILE}" \
    "${FLAGS[@]}"
else
  gh release create "${TAG}" \
    --target "${TARGET}" \
    --title "LimitLens ${VERSION}" \
    --notes-file "${NOTES_FILE}" \
    "${CLI_TARBALL}" \
    "${DMG_FILE}"
fi

echo "[release] Created ${TAG}."

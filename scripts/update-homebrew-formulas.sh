#!/usr/bin/env bash
#
# This script updates Homebrew Formula/Cask version and SHA values for a LimitLens
# release. It keeps release metadata edits deterministic before publishing to a tap.
#
# It exists as a separate script because manual formula edits are error-prone and easy
# to forget during release flow.
#
# This script talks to local packaging files under `packaging/homebrew`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORMULA_FILE="${ROOT_DIR}/packaging/homebrew/Formula/limitlens.rb"
CASK_FILE="${ROOT_DIR}/packaging/homebrew/Casks/limitlens-app.rb"

VERSION=""
CLI_SHA256=""
APP_SHA256=""

usage() {
  cat <<'USAGE'
Usage: bash scripts/update-homebrew-formulas.sh --version <semver> --cli-sha256 <sha> --app-sha256 <sha>
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --cli-sha256)
      CLI_SHA256="${2:-}"
      shift 2
      ;;
    --app-sha256)
      APP_SHA256="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[homebrew] ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" || -z "${CLI_SHA256}" || -z "${APP_SHA256}" ]]; then
  usage
  exit 1
fi

# We only replace targeted metadata lines to preserve comments and structure.
sed -E -i '' "s/version \"[0-9.]+\"/version \"${VERSION}\"/" "${FORMULA_FILE}"
sed -E -i '' "s/sha256 \"[a-f0-9]{64}\"/sha256 \"${CLI_SHA256}\"/" "${FORMULA_FILE}"

sed -E -i '' "s/version \"[0-9.]+\"/version \"${VERSION}\"/" "${CASK_FILE}"
sed -E -i '' "s/sha256 \"[a-f0-9]{64}\"/sha256 \"${APP_SHA256}\"/" "${CASK_FILE}"

echo "[homebrew] Updated formula and cask for version ${VERSION}."

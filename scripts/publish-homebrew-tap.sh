#!/usr/bin/env bash
#
# This script syncs local Homebrew tap assets to a dedicated tap repository.
# It automates copy + commit + push so release distribution stays repeatable.
#
# It exists as a separate script because tap publication is repository orchestration,
# not product runtime behavior.
#
# This script talks to git/gh and expects push access to the target tap repository.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAP_REPO="darpansmiles/homebrew-limitlens"
WORK_DIR=""
NO_PUSH=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/publish-homebrew-tap.sh [options]

Options:
  --tap-repo <owner/repo>   Tap repository. Default: darpansmiles/homebrew-limitlens
  --work-dir <path>         Optional existing local tap checkout.
  --no-push                 Commit locally but skip push.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap-repo)
      TAP_REPO="${2:-}"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="${2:-}"
      shift 2
      ;;
    --no-push)
      NO_PUSH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[tap] ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${WORK_DIR}" ]]; then
  WORK_DIR="$(mktemp -d /tmp/limitlens-tap-XXXXXX)"
  git clone "https://github.com/${TAP_REPO}.git" "${WORK_DIR}"
fi

mkdir -p "${WORK_DIR}/Formula" "${WORK_DIR}/Casks"
cp "${ROOT_DIR}/packaging/homebrew/Formula/limitlens.rb" "${WORK_DIR}/Formula/limitlens.rb"
cp "${ROOT_DIR}/packaging/homebrew/Casks/limitlens-app.rb" "${WORK_DIR}/Casks/limitlens-app.rb"

(
  cd "${WORK_DIR}"
  git add Formula/limitlens.rb Casks/limitlens-app.rb
  if git diff --cached --quiet; then
    echo "[tap] No changes to publish."
    exit 0
  fi

  git commit -m "chore: update LimitLens formula and cask"

  if [[ "${NO_PUSH}" -eq 0 ]]; then
    git push origin HEAD
    echo "[tap] Published updates to ${TAP_REPO}."
  else
    echo "[tap] Commit created locally in ${WORK_DIR}; push skipped (--no-push)."
  fi
)

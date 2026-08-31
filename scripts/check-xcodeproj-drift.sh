#!/usr/bin/env bash
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
set -euo pipefail

# swift-unit regenerates Engram.xcodeproj with a pinned xcodegen and fails on any
# diff. Reproduce that gate locally so drift costs a commit, not a CI round trip.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/test.yml"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/engram/xcodegen"

version="$(sed -n 's/^  XCODEGEN_VERSION: "\(.*\)"$/\1/p' "$WORKFLOW")"
sha256="$(sed -n 's/^  XCODEGEN_SHA256: "\(.*\)"$/\1/p' "$WORKFLOW")"
if [ -z "$version" ] || [ -z "$sha256" ]; then
  echo "check-xcodeproj-drift: no XCODEGEN_VERSION/XCODEGEN_SHA256 in $WORKFLOW" >&2
  exit 1
fi

find_pinned() {
  if [ -n "${XCODEGEN_BIN:-}" ]; then
    [ -x "${XCODEGEN_BIN}" ] || return 1
    echo "${XCODEGEN_BIN}"
    return 0
  fi
  local cached
  for cached in "$CACHE_ROOT/xcodegen-$version".*/xcodegen/bin/xcodegen; do
    if [ -x "$cached" ]; then
      echo "$cached"
      return 0
    fi
  done
  if command -v xcodegen >/dev/null 2>&1 &&
    [ "$(xcodegen --version)" = "Version: $version" ]; then
    command -v xcodegen
    return 0
  fi
  return 1
}

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$CACHE_ROOT"
  RUNNER_TEMP="$CACHE_ROOT" GITHUB_PATH=/dev/null \
    bash "$ROOT_DIR/scripts/ci/install-xcodegen.sh" "$version" "$sha256"
fi

if ! bin="$(find_pinned)"; then
  local_version="$(command -v xcodegen >/dev/null 2>&1 && xcodegen --version || echo "not installed")"
  echo "check-xcodeproj-drift: needs xcodegen $version (the swift-unit pin)" >&2
  echo "  on PATH: $local_version" >&2
  echo "  a different version writes a project.pbxproj that CI rejects" >&2
  echo "  install the pinned build once: scripts/check-xcodeproj-drift.sh --install" >&2
  exit 1
fi

cd "$ROOT_DIR/macos"
"$bin" generate >/dev/null
unstaged="$(git diff --name-only -- Engram.xcodeproj)"
untracked="$(git ls-files --others --exclude-standard -- Engram.xcodeproj)"
if [ -n "$unstaged" ] || [ -n "$untracked" ]; then
  echo "check-xcodeproj-drift: Engram.xcodeproj was stale and has been regenerated." >&2
  echo "  New or renamed Swift files are not in the build until this is committed," >&2
  echo "  so their tests never compile and never run. Stage it:" >&2
  echo "    git add macos/Engram.xcodeproj" >&2
  exit 1
fi

echo "xcodeproj drift ok"

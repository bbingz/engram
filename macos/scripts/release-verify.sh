#!/bin/bash
# macos/scripts/release-verify.sh
# Reusable post-build verification for an exported Engram.app.
#
# Always runs (identity-independent):
#   - Bundle hygiene: NONE of node / node_modules / dist / daemon.js / index.js / web.js
#   - Structural sanity: required Helpers + executable present
#   - Version: CFBundleVersion / CFBundleShortVersionString are non-default-or-empty
#   - codesign --verify --deep --strict (works for ad-hoc and Developer ID)
#
# Distribution-only (skipped under --adhoc): requires a notarizable Developer ID build:
#   - Hardened Runtime flag present  (codesign -dvvv | flags=...runtime)
#   - Developer ID Application authority
#   - Secure timestamp present
#
# Usage:
#   release-verify.sh /path/to/Engram.app [--adhoc] [--expected-build N] [--expected-short-version X.Y.Z]
#
# Exit nonzero on the first failed assertion.
set -euo pipefail

APP="${1:-}"
shift || true

ADHOC=0
EXPECTED_BUILD=""
EXPECTED_SHORT_VERSION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --adhoc) ADHOC=1 ;;
    --expected-build) shift; EXPECTED_BUILD="${1:-}" ;;
    --expected-short-version) shift; EXPECTED_SHORT_VERSION="${1:-}" ;;
    *) echo "release-verify: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "release-verify: app bundle not found: '$APP'" >&2
  exit 1
fi

fail() { echo "release-verify: FAIL: $*" >&2; exit 1; }
ok() { echo "release-verify: ok: $*"; }

echo "======================================"
echo " release-verify: $APP"
echo " mode: $([ "$ADHOC" -eq 1 ] && echo 'ad-hoc (hygiene/structure only)' || echo 'Developer ID (full)')"
echo "======================================"

# --- 1. Bundle hygiene: forbidden Node/dist artifacts must be absent ---
FORBIDDEN_NAMES=(node node_modules dist daemon.js index.js web.js)
hygiene_failed=0
for name in "${FORBIDDEN_NAMES[@]}"; do
  matches="$(find "$APP" -name "$name" 2>/dev/null || true)"
  if [ -n "$matches" ]; then
    echo "release-verify: FAIL: forbidden bundle artifact '$name' found:" >&2
    echo "$matches" >&2
    hygiene_failed=1
  fi
done
# Explicit check for the documented Resources/node path.
if [ -e "$APP/Contents/Resources/node" ]; then
  echo "release-verify: FAIL: Contents/Resources/node present" >&2
  hygiene_failed=1
fi
[ "$hygiene_failed" -eq 0 ] || fail "bundle hygiene check failed (Node/dist artifacts present)"
ok "bundle hygiene clean (no node/node_modules/dist/daemon.js/index.js/web.js)"

# --- 2. Structural sanity ---
[ -f "$APP/Contents/MacOS/Engram" ] || fail "missing main executable Contents/MacOS/Engram"
[ -f "$APP/Contents/Helpers/EngramMCP" ] || fail "missing Contents/Helpers/EngramMCP"
[ -f "$APP/Contents/Helpers/EngramService" ] || fail "missing Contents/Helpers/EngramService"
ok "structure present (Engram + EngramMCP + EngramService)"

# --- 3. Version is non-default / non-empty ---
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || fail "missing Info.plist"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST" 2>/dev/null || echo "")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "")"
[ -n "$BUNDLE_VERSION" ] || fail "CFBundleVersion is empty"
[ -n "$SHORT_VERSION" ] || fail "CFBundleShortVersionString is empty"
# Reject unsubstituted xcodegen/Xcode tokens.
case "$BUNDLE_VERSION$SHORT_VERSION" in
  *'$('*) fail "version contains unsubstituted build-setting token: short=$SHORT_VERSION build=$BUNDLE_VERSION" ;;
esac
ok "version short=$SHORT_VERSION build=$BUNDLE_VERSION"
if [ -n "$EXPECTED_BUILD" ] && [ "$BUNDLE_VERSION" != "$EXPECTED_BUILD" ]; then
  fail "CFBundleVersion '$BUNDLE_VERSION' != expected '$EXPECTED_BUILD'"
fi
if [ -n "$EXPECTED_SHORT_VERSION" ] && [ "$SHORT_VERSION" != "$EXPECTED_SHORT_VERSION" ]; then
  fail "CFBundleShortVersionString '$SHORT_VERSION' != expected '$EXPECTED_SHORT_VERSION'"
fi

# --- 4. Signature validity (deep + strict) ---
codesign --verify --deep --strict --verbose=2 "$APP" || fail "codesign --verify --deep --strict failed"
ok "codesign --verify --deep --strict passed"

if [ "$ADHOC" -eq 1 ]; then
  echo "release-verify: ad-hoc mode — skipping Hardened Runtime / Developer ID / timestamp assertions"
  echo "release-verify: PASS (hygiene + structure + version + deep verify)"
  exit 0
fi

# --- 5. Distribution-only signature assertions ---
SIGN_INFO="$(codesign -dvvv "$APP" 2>&1)"

echo "$SIGN_INFO" | grep -Eq 'flags=.*runtime' \
  || fail "Hardened Runtime flag absent (expected codesign flags to contain 'runtime')"
ok "Hardened Runtime flag present"

echo "$SIGN_INFO" | grep -Eq 'Authority=Developer ID Application' \
  || fail "Developer ID Application authority absent (found: $(echo "$SIGN_INFO" | grep -m1 '^Authority=' || echo none))"
ok "Developer ID Application authority present"

# Secure timestamp: codesign prints a 'Timestamp=' (TSA) line for secure timestamps.
# 'Signed Time=' alone is the local clock and is NOT a secure timestamp.
if echo "$SIGN_INFO" | grep -Eq '^Timestamp='; then
  ok "secure timestamp present"
else
  fail "secure timestamp absent (no 'Timestamp=' line; 'Signed Time=' is not a secure timestamp)"
fi

echo "release-verify: PASS (full Developer ID verification)"

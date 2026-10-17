#!/usr/bin/env bash
# Real-binary chain gate (plan W6 item 2): build the Debug EngramCollector,
# EngramService and EngramRemoteServer tools, run the real-binary XCTest
# classes against them, and fail unless the expected test set actually ran.
# Used by .github/workflows/real-binary.yml and for a local Mac receipt.
#
# Usage: run-real-binary-gate.sh --out DIR [--derived-data DIR]
#                                [--cloned-source-packages DIR]
set -euo pipefail

usage() {
  echo "usage: $0 --out DIR [--derived-data DIR] [--cloned-source-packages DIR]" >&2
  exit 2
}

if [ "$(uname -s)" != "Darwin" ]; then
  echo "run-real-binary-gate.sh requires macOS" >&2
  exit 2
fi

OUT=""
DD=""
SPM=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --derived-data) [ "$#" -ge 2 ] || usage; DD="$2"; shift 2 ;;
    --cloned-source-packages) [ "$#" -ge 2 ] || usage; SPM="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$OUT" ] || usage

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
  echo "--out $OUT must not exist or must be empty" >&2
  exit 2
fi
mkdir -p "$OUT"
chmod 700 "$OUT"
OUT="$(cd "$OUT" && pwd)"
if [ -z "$DD" ]; then
  DD="$(mktemp -d /private/tmp/engram-real-binary-dd.XXXXXX)"
fi

# Record the checkout state before building so the receipt names what was built.
git_sha="$(git -C "$ROOT" rev-parse HEAD)"
dirty="$(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ')"

common=(
  -project "$ROOT/macos/Engram.xcodeproj"
  -configuration Debug
  -destination 'platform=macOS'
  -derivedDataPath "$DD"
)
if [ -n "$SPM" ]; then
  common+=(-clonedSourcePackagesDirPath "$SPM")
fi
common+=(CODE_SIGNING_ALLOWED=NO)

for scheme in EngramCollector EngramService EngramRemoteServer; do
  xcodebuild build -scheme "$scheme" "${common[@]}" 2>&1 | tee -a "$OUT/build.log"
done
xcodebuild build-for-testing -scheme EngramServiceCore "${common[@]}" 2>&1 | tee -a "$OUT/build.log"

P="$DD/Build/Products/Debug"
COLLECTOR="$P/EngramCollector"
SERVICE="$P/EngramService"
REMOTE="$P/EngramRemoteServer"
for binary in "$COLLECTOR" "$SERVICE" "$REMOTE"; do
  if [ ! -x "$binary" ]; then
    echo "missing built binary: $binary" >&2
    exit 1
  fi
done

# Same CFFIXED_USER_HOME isolation as the swift-unit EngramServiceCore run:
# invariant 6 (tests avoid production Engram data).
TEST_HOME="$(mktemp -d "$OUT/test-home.XXXXXX")"
chmod 700 "$TEST_HOME"

# ENGRAM_SHADOW_* is deliberately never set here: the browser demo stays an
# operator opt-in and is the only test the verifier allows to skip.
set +e
env \
  ENGRAM_COLLECTOR_BINARY="$COLLECTOR" \
  TEST_RUNNER_ENGRAM_COLLECTOR_BINARY="$COLLECTOR" \
  ENGRAM_SERVICE_BINARY="$SERVICE" \
  TEST_RUNNER_ENGRAM_SERVICE_BINARY="$SERVICE" \
  ENGRAM_REMOTE_SERVER_BINARY="$REMOTE" \
  TEST_RUNNER_ENGRAM_REMOTE_SERVER_BINARY="$REMOTE" \
  CFFIXED_USER_HOME="$TEST_HOME" \
  TEST_RUNNER_CFFIXED_USER_HOME="$TEST_HOME" \
  xcodebuild test-without-building -scheme EngramServiceCore "${common[@]}" \
    -only-testing:EngramServiceCoreTests/CollectorBinaryShadowIntegrationTests \
    -only-testing:EngramServiceCoreTests/CollectorLargeHistoryBinaryTests \
    -only-testing:EngramServiceCoreTests/CollectorCLIIntegrationTests \
    -resultBundlePath "$OUT/real-binary.xcresult" \
    2>&1 | tee "$OUT/test.log"
rc=${PIPESTATUS[0]}

if [ -d "$OUT/real-binary.xcresult" ]; then
  xcrun xcresulttool get test-results tests --path "$OUT/real-binary.xcresult" >"$OUT/tests.json"
else
  : >"$OUT/tests.json"
fi

tests_dir="$ROOT/macos/EngramServiceCoreTests"
python3 "$ROOT/scripts/ci/check-real-binary-results.py" \
  --tests-json "$OUT/tests.json" \
  --source "$tests_dir/CollectorBinaryShadowIntegrationTests.swift" \
  --source "$tests_dir/CollectorCLIIntegrationTests.swift" \
  --allow-skip testRealBinaryHTTPSBrowserDemoWithBoundedHold \
  --xcodebuild-exit-code "$rc" \
  --binary collector="$COLLECTOR" \
  --binary service="$SERVICE" \
  --binary remote-server="$REMOTE" \
  --git-sha "$git_sha" \
  --xcode-version "$(xcodebuild -version | tr '\n' ' ')" \
  --dirty-paths "$dirty" \
  --receipt "$OUT/receipt.json" \
  --summary "$OUT/receipt.md"

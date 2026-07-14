#!/usr/bin/env bash

set -euo pipefail

changes_result="${1:-}"
heavy="${2:-}"
typescript_result="${3:-}"
macos_gates_result="${4:-}"
swift_unit_result="${5:-}"
remote_server_result="${6:-}"
ui_smoke_result="${7:-}"
ui_full_result="${8:-}"
event_name="${9:-}"

require_result() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "$name: expected $expected, got ${actual:-<empty>}" >&2
    exit 1
  fi
}

case "$heavy" in
  true|false)
    ;;
  *)
    echo "heavy: expected true or false, got '${heavy:-<empty>}'" >&2
    exit 1
    ;;
esac

require_result changes "$changes_result" success

if [ "$heavy" = "true" ]; then
  require_result typescript "$typescript_result" success
  require_result macos-gates "$macos_gates_result" success
  require_result swift-unit "$swift_unit_result" success
  require_result remote-server "$remote_server_result" success
  if [ "$event_name" = "pull_request" ]; then
    require_result ui-smoke "$ui_smoke_result" success
    require_result ui-full "$ui_full_result" skipped
  else
    require_result ui-smoke "$ui_smoke_result" skipped
    require_result ui-full "$ui_full_result" success
  fi
else
  require_result typescript "$typescript_result" skipped
  require_result macos-gates "$macos_gates_result" skipped
  require_result swift-unit "$swift_unit_result" skipped
  require_result remote-server "$remote_server_result" skipped
  require_result ui-smoke "$ui_smoke_result" skipped
  require_result ui-full "$ui_full_result" skipped
fi

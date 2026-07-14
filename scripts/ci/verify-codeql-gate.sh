#!/usr/bin/env bash

set -euo pipefail

changes_result="${1:-}"
typescript_required="${2:-}"
typescript_result="${3:-}"
swift_product_required="${4:-}"
swift_product_result="${5:-}"
swift_remote_required="${6:-}"
swift_remote_result="${7:-}"

require_result() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "$name: expected $expected, got $actual" >&2
    exit 1
  fi
}

require_boolean() {
  local name="$1"
  local actual="$2"
  case "$actual" in
    true|false)
      ;;
    *)
      echo "$name: expected true or false, got '${actual:-<empty>}'" >&2
      exit 1
      ;;
  esac
}

expected_result() {
  if [ "$1" = "true" ]; then
    echo success
  else
    echo skipped
  fi
}

require_result changes "$changes_result" success
require_boolean typescript-required "$typescript_required"
require_boolean swift-product-required "$swift_product_required"
require_boolean swift-remote-server-required "$swift_remote_required"
require_result typescript "$typescript_result" "$(expected_result "$typescript_required")"
require_result swift-product "$swift_product_result" "$(expected_result "$swift_product_required")"
require_result swift-remote-server "$swift_remote_result" "$(expected_result "$swift_remote_required")"

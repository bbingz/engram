#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/check-swift-conventions.sh [scan-root]
#
# The optional scan-root lets tests run the same gate against a temp tree. Paths
# in reports and allowlist entries are relative to that scan root.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN_ROOT="${1:-$ROOT_DIR}"
ALLOWLIST="${ENGRAM_SWIFT_CONVENTIONS_ALLOWLIST:-$ROOT_DIR/scripts/swift-conventions-allowlist.txt}"

if [[ "$SCAN_ROOT" != /* ]]; then
  SCAN_ROOT="$PWD/$SCAN_ROOT"
fi

if [[ ! -d "$SCAN_ROOT" ]]; then
  echo "swift conventions scan root not found: $SCAN_ROOT" >&2
  exit 1
fi

if [[ ! -f "$ALLOWLIST" ]]; then
  echo "swift conventions allowlist not found: $ALLOWLIST" >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "rg not found" >&2
  exit 1
fi

declare -a allow_rules=()
declare -a allow_paths=()
declare -a allow_substrings=()

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

validate_rule_id() {
  case "$1" in
    R1|R2|R3) return 0 ;;
    *) return 1 ;;
  esac
}

load_allowlist() {
  local line line_no comment entry rule rest path substring
  line_no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    entry="$(trim "$line")"
    [[ -z "$entry" || "$entry" == \#* ]] && continue

    if [[ "$line" != *#* ]]; then
      echo "$ALLOWLIST:$line_no: allowlist entry needs an explanatory comment" >&2
      exit 1
    fi

    comment="$(trim "${line#*#}")"
    if [[ -z "$comment" ]]; then
      echo "$ALLOWLIST:$line_no: allowlist entry comment is empty" >&2
      exit 1
    fi

    entry="$(trim "${line%%#*}")"
    rule="${entry%%[[:space:]]*}"
    rest="$(trim "${entry#"$rule"}")"
    path="${rest%%[[:space:]]*}"
    substring=""
    if [[ "$rest" != "$path" ]]; then
      substring="$(trim "${rest#"$path"}")"
    fi

    if ! validate_rule_id "$rule"; then
      echo "$ALLOWLIST:$line_no: unknown rule id: $rule" >&2
      exit 1
    fi
    if [[ -z "$path" ]]; then
      echo "$ALLOWLIST:$line_no: allowlist entry needs a repo-relative path" >&2
      exit 1
    fi

    allow_rules+=("$rule")
    allow_paths+=("$path")
    allow_substrings+=("$substring")
  done <"$ALLOWLIST"
}

is_allowlisted() {
  local rule="$1"
  local path="$2"
  local text="$3"
  local i substring
  for ((i = 0; i < ${#allow_rules[@]}; i++)); do
    [[ "${allow_rules[$i]}" == "$rule" ]] || continue
    [[ "${allow_paths[$i]}" == "$path" ]] || continue
    substring="${allow_substrings[$i]}"
    if [[ -z "$substring" || "$text" == *"$substring"* ]]; then
      return 0
    fi
  done
  return 1
}

is_test_swift_path() {
  local path="$1"
  [[ "$path" == macos/* ]] || return 1
  [[ "$path" == *.swift ]] || return 1
  [[ "$path" =~ ^macos/[^/]*Tests[^/]*/ || "$path" == *Tests.swift ]]
}

is_product_swift_path() {
  local path="$1"
  [[ "$path" == *.swift ]] || return 1
  case "$path" in
    macos/Engram/*|macos/Shared/*|macos/EngramMCP/*|macos/EngramService/*|macos/EngramCoreWrite/*|macos/EngramCoreRead/*) ;;
    *) return 1 ;;
  esac
  [[ "$path" != *Tests* ]]
}

rule_name() {
  case "$1" in
    R1) echo "test-home-isolation" ;;
    R2) echo "no-hashvalue-keys" ;;
    R3) echo "no-node-runtime" ;;
  esac
}

declare -a violations=()

record_violation() {
  local rule="$1"
  local path="$2"
  local line="$3"
  local text="$4"
  if is_allowlisted "$rule" "$path" "$text"; then
    return
  fi
  violations+=("$rule $(rule_name "$rule"): $path:$line:$text")
}

existing_product_roots() {
  local dir
  for dir in \
    macos/Engram \
    macos/Shared \
    macos/EngramMCP \
    macos/EngramService \
    macos/EngramCoreWrite \
    macos/EngramCoreRead
  do
    [[ -d "$dir" ]] && printf '%s\n' "$dir"
  done
}

load_allowlist
cd "$SCAN_ROOT"

if [[ -d macos ]]; then
  while IFS=: read -r path line text; do
    [[ -z "${path:-}" || -z "${line:-}" ]] && continue
    if is_test_swift_path "$path"; then
      record_violation "R1" "$path" "$line" "$text"
    fi
  done < <(rg -n --no-heading -F 'NSHomeDirectory()' macos --glob '*.swift' || true)
fi

product_roots=()
while IFS= read -r dir; do
  product_roots+=("$dir")
done < <(existing_product_roots)

if (( ${#product_roots[@]} > 0 )); then
  while IFS=: read -r path line text; do
    [[ -z "${path:-}" || -z "${line:-}" ]] && continue
    if is_product_swift_path "$path"; then
      record_violation "R2" "$path" "$line" "$text"
    fi
  done < <(rg -n --no-heading '\.hashValue' "${product_roots[@]}" --glob '*.swift' || true)

  while IFS=: read -r path line text; do
    [[ -z "${path:-}" || -z "${line:-}" ]] && continue
    if is_product_swift_path "$path"; then
      record_violation "R3" "$path" "$line" "$text"
    fi
  done < <(rg -n --no-heading 'node_modules|daemon\.js|web\.js|/usr/bin/env node|"npm' "${product_roots[@]}" --glob '*.swift' || true)
fi

if (( ${#violations[@]} > 0 )); then
  printf '%s\n' "${violations[@]}" >&2
  exit 1
fi

echo "swift conventions ok"

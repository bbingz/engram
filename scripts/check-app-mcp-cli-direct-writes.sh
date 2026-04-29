#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

PATTERN='DatabasePool\(path:|DatabaseQueue\(|\.write[[:space:]]*\{|execute\(sql:|sql:[[:space:]]*"((DELETE FROM|UPDATE|INSERT INTO)[^"]*)'

READ_ONLY_DB_FILES=(
  "macos/Engram/Core/Database.swift"
  "macos/Engram/Core/MessageParser.swift"
  "macos/EngramMCP/Core/MCPDatabase.swift"
)

contains_path() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

classify_hit() {
  local path="$1"

  if contains_path "$path" "${READ_ONLY_DB_FILES[@]}"; then
    echo "ALLOW_READ_ONLY_DB"
  else
    echo "FAIL_UNCLASSIFIED"
  fi
}

format_hit() {
  local path="$1"
  local line="$2"
  local text="$3"
  printf '%s:%s: %s\n' "$path" "$line" "$text"
}

declare -a unclassified_failures=()
declare -a read_only_hits=()

while IFS=: read -r path line text; do
  [[ -z "${path:-}" || -z "${line:-}" ]] && continue
  category="$(classify_hit "$path")"
  case "$category" in
    ALLOW_READ_ONLY_DB)
      read_only_hits+=("$(format_hit "$path" "$line" "$text")")
      ;;
    FAIL_UNCLASSIFIED)
      unclassified_failures+=("$(format_hit "$path" "$line" "$text")")
      ;;
  esac
done < <(
  rg -n --no-heading "$PATTERN" \
    macos/Engram \
    macos/EngramMCP \
    macos/EngramCLI \
    macos/Shared \
    --glob '*.swift' \
    --glob '!macos/Engram/TestSupport/**' \
    --glob '!macos/EngramTests/**' \
    --glob '!macos/EngramMCPTests/**' \
    --glob '!macos/EngramServiceCoreTests/**' \
    --glob '!**/.build/**' || true
)

if (( ${#unclassified_failures[@]} > 0 )); then
  {
    echo "direct write scan failed"
    echo
    echo "Unclassified app/MCP/CLI direct write affordances need migration or an explicit allowlist entry in scripts/check-app-mcp-cli-direct-writes.sh:"
    printf '%s\n' "${unclassified_failures[@]}"
    echo
    echo "The scan intentionally ignores collection/keychain/client insert/delete calls; only GRDB writer affordances are classified."
  } >&2
  exit 1
fi

echo "direct write scan ok"
echo
echo "Allowed legacy app DB writer hits:"
echo "none"
echo
echo "Allowed Stage 4 MCP DB/project-op hits:"
echo "none"
echo
echo "Allowed read-only DB hits (not second-writer paths):"
if (( ${#read_only_hits[@]} > 0 )); then
  printf '%s\n' "${read_only_hits[@]}"
else
  echo "none"
fi

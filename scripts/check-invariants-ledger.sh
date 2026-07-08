#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER="${1:-$ROOT_DIR/docs/invariants.md}"

if [[ ! -f "$LEDGER" ]]; then
  echo "invariants ledger not found: $LEDGER" >&2
  exit 1
fi

paths_file="$(mktemp)"
trap 'rm -f "$paths_file"' EXIT

python3 - "$LEDGER" >"$paths_file" <<'PY'
import re
import sys
from pathlib import Path

ledger = Path(sys.argv[1])
text = ledger.read_text(encoding="utf-8")
prefixes = (
    "macos/",
    "src/",
    "scripts/",
    "tests/",
    "test-fixtures/",
    "docs/",
    ".github/",
)
root_paths = (
    "AGENTS.md",
    "CLAUDE.md",
)

seen = set()
for token in re.findall(r"`([^`]+)`", text):
    candidate = re.sub(r":\d+$", "", token.strip())
    if not candidate.startswith(prefixes) and candidate not in root_paths:
        continue
    if candidate and candidate not in seen:
        seen.add(candidate)
        print(candidate)
PY

missing=0
while IFS= read -r path; do
  if [[ -z "$path" ]]; then
    continue
  fi
  if [[ ! -e "$ROOT_DIR/$path" ]]; then
    echo "$LEDGER: missing path: $path" >&2
    missing=1
  fi
done <"$paths_file"

if ((missing)); then
  exit 1
fi

echo "invariants ledger ok"

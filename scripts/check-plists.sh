#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v plutil >/dev/null 2>&1; then
  echo "plutil not found" >&2
  exit 1
fi

if (($# > 0)); then
  files=("$@")
else
  files=()
  while IFS= read -r file; do
    files+=("$file")
  done < <(cd "$ROOT_DIR" && git ls-files '*.plist' '*.entitlements')
  cd "$ROOT_DIR"
fi

for file in "${files[@]}"; do
  plutil -lint "$file" >/dev/null

  python3 - "$file" <<'PY'
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_bytes()
if data.startswith(b"bplist00"):
    print(f"{path}: binary plist, duplicate-key check skipped")
    sys.exit(0)

try:
    root = ET.fromstring(data)
except ET.ParseError as exc:
    print(f"{path}: XML parse failed during duplicate-key check: {exc}", file=sys.stderr)
    sys.exit(1)


def tag_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


violations = []
for dict_element in root.iter():
    if tag_name(dict_element.tag) != "dict":
        continue
    keys = [
        (child.text or "")
        for child in list(dict_element)
        if tag_name(child.tag) == "key"
    ]
    for key, count in Counter(keys).items():
        if count > 1:
            violations.append(key)

if violations:
    for key in sorted(set(violations)):
        print(f"{path}: duplicate plist key: {key}", file=sys.stderr)
    sys.exit(1)
PY
done

echo "plists ok"

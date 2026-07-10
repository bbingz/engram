#!/usr/bin/env bash
# L09: allowlisted invariant gate runner.
# - Validates ledger path anchors still exist.
# - Executes only gates registered in scripts/invariant-gates.json
#   (invariant ID → gate ID → fixed argv). Never turns markdown into shell.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER="${1:-$ROOT_DIR/docs/invariants.md}"
GATES_JSON="${2:-$ROOT_DIR/scripts/invariant-gates.json}"

if [[ ! -f "$LEDGER" ]]; then
  echo "invariants ledger not found: $LEDGER" >&2
  exit 1
fi

if [[ ! -f "$GATES_JSON" ]]; then
  echo "invariant gates registry not found: $GATES_JSON" >&2
  exit 1
fi

paths_file="$(mktemp)"
gates_plan="$(mktemp)"
trap 'rm -f "$paths_file" "$gates_plan"' EXIT

# Extract checked path anchors from the ledger markdown (path existence only).
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

# Plan executable gates from the allowlisted registry. Never reads shell from markdown.
python3 - "$GATES_JSON" "$ROOT_DIR" >"$gates_plan" <<'PY'
import json
import sys
from pathlib import Path

gates_path = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()

try:
    registry = json.loads(gates_path.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    print(f"invalid invariant gates registry JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(registry, dict):
    print("invalid invariant gates registry: root must be an object", file=sys.stderr)
    sys.exit(1)

gates = registry.get("gates")
invariants = registry.get("invariants")
if not isinstance(gates, dict) or not gates:
    print("invalid invariant gates registry: missing non-empty 'gates' object", file=sys.stderr)
    sys.exit(1)
if not isinstance(invariants, dict) or not invariants:
    print("invalid invariant gates registry: missing non-empty 'invariants' object", file=sys.stderr)
    sys.exit(1)

errors = []
referenced = set()

for inv_id, gate_ids in invariants.items():
    if not isinstance(gate_ids, list) or not gate_ids:
        errors.append(f"invariant {inv_id!r}: expected non-empty gate id list")
        continue
    for gate_id in gate_ids:
        if not isinstance(gate_id, str) or not gate_id:
            errors.append(f"invariant {inv_id!r}: gate id must be a non-empty string")
            continue
        if gate_id not in gates:
            errors.append(f"invariant {inv_id!r}: unknown gate id {gate_id!r}")
            continue
        referenced.add(gate_id)

# Exact argv schema for type=argv gates:
#   ["bash", "scripts/<repo-owned>.sh"]
# Reject extra flags/args, -c, control tokens, non-bash interpreters, path
# escapes, and symlink escapes. Registry strings never become free-form shell.
import os
import re

SCRIPT_REL_RE = re.compile(r"^scripts/[A-Za-z0-9][A-Za-z0-9._/-]*\.sh$")
scripts_root = (root / "scripts").resolve()

planned = []  # list of (gate_id, argv)
for gate_id, spec in gates.items():
    if not isinstance(spec, dict):
        errors.append(f"gate {gate_id!r}: spec must be an object")
        continue
    gate_type = spec.get("type")
    if gate_type == "ledger-paths":
        # Already executed above as the path-existence pass.
        continue
    if gate_type != "argv":
        errors.append(f"gate {gate_id!r}: unsupported type {gate_type!r}")
        continue
    argv = spec.get("argv")
    if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        errors.append(f"gate {gate_id!r}: argv must be a string list")
        continue
    if len(argv) != 2 or argv[0] != "bash" or not argv[1]:
        errors.append(
            f"gate {gate_id!r}: invalid argv: exact argv schema requires "
            f'exactly ["bash", "scripts/<repo-owned>.sh"]'
        )
        continue
    script = argv[1]
    # Reject control characters, absolute paths, parent traversal, and flags.
    if any(ch in script for ch in ("\0", "\n", "\r", "\t")):
        errors.append(f"gate {gate_id!r}: invalid argv: script path contains control characters")
        continue
    if script.startswith("-") or script.startswith("/") or "\\" in script:
        errors.append(
            f"gate {gate_id!r}: invalid argv: exact argv schema requires "
            f'exactly ["bash", "scripts/<repo-owned>.sh"]'
        )
        continue
    if ".." in script.split("/"):
        errors.append(f"gate {gate_id!r}: invalid argv: path escapes via '..'")
        continue
    if not SCRIPT_REL_RE.fullmatch(script):
        errors.append(
            f"gate {gate_id!r}: invalid argv: exact argv schema requires "
            f'exactly ["bash", "scripts/<repo-owned>.sh"]'
        )
        continue
    # Resolve under repo scripts/ and reject symlink escapes outside scripts/.
    candidate = root / script
    if candidate.is_symlink():
        # Allow only if the final resolved target still lives under scripts/.
        pass
    try:
        abs_script = candidate.resolve(strict=True)
    except FileNotFoundError:
        errors.append(f"gate {gate_id!r}: missing script {script}")
        continue
    except OSError as exc:
        errors.append(f"gate {gate_id!r}: cannot resolve script {script}: {exc}")
        continue
    try:
        abs_script.relative_to(scripts_root)
    except ValueError:
        errors.append(f"gate {gate_id!r}: path {script!r} escapes scripts/ (symlink or resolve)")
        continue
    if not abs_script.is_file() or not os.access(abs_script, os.R_OK):
        errors.append(f"gate {gate_id!r}: missing readable script {script}")
        continue
    # Final argv is the validated exact pair only — never pass through extras.
    planned.append((gate_id, ["bash", script]))

if errors:
    for err in errors:
        print(err, file=sys.stderr)
    sys.exit(1)

if not referenced:
    print("invalid invariant gates registry: no gate references in invariants", file=sys.stderr)
    sys.exit(1)

for gate_id, argv in planned:
    # One gate per line: gate_id<TAB>json-array-argv
    print(gate_id + "\t" + json.dumps(argv))
PY

# Execute each planned allowlisted gate exactly once.
while IFS=$'\t' read -r gate_id argv_json; do
  if [[ -z "${gate_id:-}" ]]; then
    continue
  fi
  # shellcheck disable=SC2207
  mapfile -t argv < <(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])))' "$argv_json")
  if ((${#argv[@]} == 0)); then
    echo "empty argv for gate: $gate_id" >&2
    exit 1
  fi
  echo "running invariant gate: $gate_id (${argv[*]})"
  (
    cd "$ROOT_DIR"
    "${argv[@]}"
  ) || {
    echo "invariant gate failed: $gate_id" >&2
    exit 1
  }
done <"$gates_plan"

echo "invariants ledger ok"

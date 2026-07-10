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

allowed_prefixes = ("scripts/",)
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

# Execute every registered gate in the registry (allowlisted argv only).
# Invariant rows must reference known gate IDs; unreferenced registry gates
# still run so the allowlist is executable, not documentation-only.
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
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and a for a in argv):
        errors.append(f"gate {gate_id!r}: argv must be a non-empty string list")
        continue
    # Allowlist: every script path component after the interpreter must live under scripts/.
    script_args = [a for a in argv if a.endswith(".sh") or a.startswith("scripts/")]
    if not script_args:
        errors.append(f"gate {gate_id!r}: argv must reference a scripts/ command")
        continue
    for script in script_args:
        rel = script
        if rel.startswith("./"):
            rel = rel[2:]
        if not rel.startswith(allowed_prefixes):
            errors.append(
                f"gate {gate_id!r}: path {script!r} is outside allowlisted scripts/ prefix"
            )
            continue
        abs_script = (root / rel).resolve()
        try:
            abs_script.relative_to(root / "scripts")
        except ValueError:
            errors.append(f"gate {gate_id!r}: path {script!r} escapes scripts/")
            continue
        if not abs_script.is_file():
            errors.append(f"gate {gate_id!r}: missing script {rel}")
    planned.append((gate_id, argv))

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

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT_DIR/macos/project.yml"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found" >&2
  exit 1
fi

SPEC_JSON="$(cd "$ROOT_DIR/macos" && xcodegen dump --spec project.yml --type json)"

node - "$SPEC_JSON" <<'NODE'
const spec = JSON.parse(process.argv[2]);
const forbiddenTargets = new Set(['Engram', 'EngramMCP', 'EngramCLI']);
const targets = spec.targets || {};
const violations = [];

for (const targetName of forbiddenTargets) {
  const deps = targets[targetName]?.dependencies || [];
  for (const dep of deps) {
    if (dep.target === 'EngramCoreWrite') {
      violations.push(`${targetName} depends on EngramCoreWrite`);
    }
  }
}

if (!targets.EngramCoreRead) violations.push('missing EngramCoreRead target');
if (!targets.EngramCoreWrite) violations.push('missing EngramCoreWrite target');
if (!targets.EngramCoreTests) violations.push('missing EngramCoreTests target');

const writeDeps = targets.EngramCoreWrite?.dependencies || [];
if (!writeDeps.some((dep) => dep.target === 'EngramCoreRead')) {
  violations.push('EngramCoreWrite must depend on EngramCoreRead');
}

if (violations.length > 0) {
  console.error(violations.join('\n'));
  process.exit(1);
}
NODE

if rg -n "import EngramCoreWrite" \
  "$ROOT_DIR/macos/Engram" \
  "$ROOT_DIR/macos/EngramMCP" \
  "$ROOT_DIR/macos/EngramCLI" \
  "$ROOT_DIR/macos/Shared" >/tmp/engram-core-write-imports.txt; then
  cat /tmp/engram-core-write-imports.txt >&2
  exit 1
fi

echo "swift module boundaries ok"

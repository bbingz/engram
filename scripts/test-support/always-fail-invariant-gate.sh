#!/usr/bin/env bash
# Fixture gate used by tests/scripts/invariants-ledger.test.ts to prove L09
# rejects present-but-behaviorally-invalid allowlisted gates.
set -euo pipefail
echo "behaviorally invalid fixture" >&2
exit 1

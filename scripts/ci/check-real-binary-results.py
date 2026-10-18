#!/usr/bin/env python3
"""Fail the real-binary chain gate unless the expected XCTest set actually ran.

The real-binary suites skip themselves when the explicit binary-path
environment variables do not reach the test runner, and a fully skipped run
still exits 0. This verifier therefore compares the exact (class, test) set
declared in the Swift sources with the Test Case nodes exported by
`xcrun xcresulttool get test-results tests`, and accepts only Passed results
(plus Skipped for explicitly allowed opt-in tests).
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path


CLASS_PATTERN = re.compile(r"^(?:final )?class (\w+): XCTestCase\b")
EXTENSION_PATTERN = re.compile(r"^extension (\w+)\b")
OTHER_TOP_LEVEL_PATTERN = re.compile(
    r"^(?:(?:private|fileprivate|public|internal|final|@\w+)\s+)*"
    r"(?:class|struct|enum|extension|actor|protocol)\b"
)
TEST_PATTERN = re.compile(r"^ {4}func (test\w+)\(")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tests-json", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path, action="append")
    parser.add_argument("--allow-skip", action="append", default=[])
    parser.add_argument("--xcodebuild-exit-code", required=True, type=int)
    parser.add_argument("--binary", action="append", default=[])
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--xcode-version", required=True)
    parser.add_argument("--dirty-paths", type=int, default=None)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    return parser.parse_args()


def expected_tests(sources: list[Path], reasons: list[str]) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for source in sources:
        try:
            lines = source.read_text().splitlines()
        except OSError as error:
            reasons.append(f"cannot read test source {source}: {error}")
            continue
        test_classes: set[str] = set()
        current: str | None = None
        for line in lines:
            class_match = CLASS_PATTERN.match(line)
            if class_match is not None:
                current = class_match.group(1)
                test_classes.add(current)
                continue
            extension_match = EXTENSION_PATTERN.match(line)
            if extension_match is not None:
                name = extension_match.group(1)
                current = name if name in test_classes else None
                continue
            if OTHER_TOP_LEVEL_PATTERN.match(line):
                current = None
                continue
            test_match = TEST_PATTERN.match(line)
            if test_match is not None and current is not None:
                found.append((current, test_match.group(1)))
    if not found:
        reasons.append("no XCTest methods found in the test sources")
    duplicates = sorted({item for item in found if found.count(item) > 1})
    for suite, name in duplicates:
        reasons.append(f"duplicate expected test {suite}/{name}")
    return sorted(set(found))


def actual_tests(path: Path, reasons: list[str]) -> list[dict[str, object]]:
    try:
        payload = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        reasons.append(f"cannot parse xcresult tests JSON {path}: {error}")
        return []
    if not isinstance(payload, dict) or not isinstance(payload.get("testNodes"), list):
        reasons.append("xcresult tests JSON has no testNodes array")
        return []

    records: list[dict[str, object]] = []

    def walk(node: object, suite: str | None) -> None:
        if not isinstance(node, dict):
            return
        node_type = node.get("nodeType")
        name = str(node.get("name", ""))
        if node_type == "Test Suite":
            suite = name
        elif node_type == "Test Case":
            if name.endswith("()"):
                name = name[:-2]
            records.append(
                {
                    "suite": suite,
                    "name": name,
                    "result": node.get("result"),
                    "durationInSeconds": node.get("durationInSeconds"),
                }
            )
            return
        for child in node.get("children") or []:
            walk(child, suite)

    for node in payload["testNodes"]:
        walk(node, None)
    if not records:
        reasons.append("xcresult contains zero Test Case nodes")
    return records


def hash_binaries(specs: list[str], reasons: list[str]) -> dict[str, dict[str, object]]:
    binaries: dict[str, dict[str, object]] = {}
    for spec in specs:
        label, separator, raw_path = spec.partition("=")
        if not separator or not label or not raw_path:
            reasons.append(f"malformed --binary {spec!r}; expected label=PATH")
            continue
        path = Path(raw_path)
        digest: str | None = None
        try:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as error:
            reasons.append(f"cannot hash binary {label} at {path}: {error}")
        binaries[label] = {"path": str(path), "sha256": digest}
    return binaries


def main() -> int:
    args = parse_args()
    reasons: list[str] = []
    if args.xcodebuild_exit_code != 0:
        reasons.append(f"xcodebuild test exited with code {args.xcodebuild_exit_code}")

    expected = expected_tests(args.source, reasons)
    records = actual_tests(args.tests_json, reasons)
    allowed_skips = set(args.allow_skip)
    expected_set = set(expected)

    seen: dict[tuple[str, str], int] = {}
    for record in records:
        key = (str(record["suite"]), str(record["name"]))
        seen[key] = seen.get(key, 0) + 1
    for suite, name in sorted(key for key, count in seen.items() if count > 1):
        reasons.append(f"duplicate result for {suite}/{name}")
    for suite, name in sorted(expected_set - set(seen)):
        reasons.append(f"expected test did not run: {suite}/{name}")
    for suite, name in sorted(set(seen) - expected_set):
        reasons.append(f"unexpected test ran: {suite}/{name}")

    passed = 0
    skipped: list[str] = []
    failed: list[str] = []
    for record in records:
        label = f"{record['suite']}/{record['name']}"
        result = record["result"]
        if result == "Passed":
            passed += 1
        elif result == "Skipped":
            skipped.append(label)
            if record["name"] not in allowed_skips:
                reasons.append(f"test skipped outside the allow-skip list: {label}")
        else:
            failed.append(label)
            reasons.append(f"test result {result!r}: {label}")

    binaries = hash_binaries(args.binary, reasons)
    status = "fail" if reasons else "pass"
    receipt = {
        "schema": 1,
        "gate": "real-binary-chain",
        "result": status,
        "git_sha": args.git_sha,
        "dirty_paths": args.dirty_paths,
        "xcode_version": args.xcode_version.strip(),
        "generated_at": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "xcodebuild_exit_code": args.xcodebuild_exit_code,
        "expected": len(expected),
        "passed": passed,
        "skipped": skipped,
        "failed": failed,
        "reasons": reasons,
        "binaries": binaries,
        "tests": records,
    }
    line = (
        f"REAL_BINARY_GATE result={status} expected={len(expected)} "
        f"passed={passed} skipped={len(skipped)} failed={len(failed)}"
    )
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    summary = [
        "## Real-binary chain",
        "",
        f"`{line}`",
        "",
        f"- git sha: `{args.git_sha}` (dirty paths: {args.dirty_paths})",
        f"- Xcode: `{args.xcode_version.strip()}`",
        f"- xcodebuild exit code: {args.xcodebuild_exit_code}",
    ]
    for label, info in sorted(binaries.items()):
        summary.append(f"- {label}: `{info['sha256']}`")
    if skipped:
        summary.append(f"- skipped: {', '.join(skipped)}")
    if reasons:
        summary.extend(["", "### Failures", ""])
        summary.extend(f"- {reason}" for reason in reasons)
    args.summary.write_text("\n".join(summary) + "\n")

    for reason in reasons:
        print(reason, file=sys.stderr)
    print(line)
    return 1 if reasons else 0


if __name__ == "__main__":
    raise SystemExit(main())

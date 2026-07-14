#!/usr/bin/env python3
"""Persist auditable XCTest perf evidence and fail closed on invalid results."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from pathlib import Path


AVERAGE_PATTERN = re.compile(r"average:\s*([0-9.]+)")
RSD_PATTERN = re.compile(r"relative standard deviation:\s*([0-9.]+)%")
WORKLOAD_PATTERN = re.compile(
    r"ENGRAM_PERF_WORKLOAD fixtures=(\d+) bytes=(\d+) indexed=(\d+)"
)
INFRASTRUCTURE_PATTERNS = (
    "timed out while waiting for connection to test runner",
    "failed to start test runner",
    "lost connection to test runner",
    "test runner exited before starting test execution",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--max-average-seconds", required=True, type=float)
    parser.add_argument("--max-rsd-percent", required=True, type=float)
    parser.add_argument("--build-exit-code", required=True, type=int)
    parser.add_argument("--test-exit-code", required=True, type=int)
    parser.add_argument("--fixture-root", required=True, type=Path)
    parser.add_argument("--expected-fixture-count", required=True, type=int)
    parser.add_argument("--baseline-id", required=True)
    parser.add_argument("--baseline-average-seconds", required=True, type=float)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--runner-name", required=True)
    parser.add_argument("--runner-os", required=True)
    parser.add_argument("--runner-arch", required=True)
    parser.add_argument("--xcode-version", required=True)
    parser.add_argument("--sdk-version", required=True)
    return parser.parse_args()


def fixture_identity(root: Path) -> tuple[int, int, str]:
    files = sorted(
        path
        for path in root.rglob("*")
        if path.is_file() and path.suffix in {".json", ".jsonl"}
    )
    digest = hashlib.sha256()
    total_bytes = 0
    for path in files:
        data = path.read_bytes()
        total_bytes += len(data)
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(data)
        digest.update(b"\0")
    return len(files), total_bytes, digest.hexdigest()


def positive_finite(value: float) -> bool:
    return math.isfinite(value) and value > 0


def main() -> int:
    args = parse_args()
    if not positive_finite(args.max_average_seconds):
        print("Performance budget must be a positive finite number", file=sys.stderr)
        return 2
    if not positive_finite(args.max_rsd_percent):
        print("RSD budget must be a positive finite number", file=sys.stderr)
        return 2
    if not positive_finite(args.baseline_average_seconds):
        print("Baseline average must be a positive finite number", file=sys.stderr)
        return 2
    if args.expected_fixture_count <= 0:
        print("Expected fixture count must be positive", file=sys.stderr)
        return 2

    log_text = args.log.read_text(errors="replace") if args.log.exists() else ""
    lines = log_text.splitlines()
    measurements: list[dict[str, object]] = []
    workloads: list[dict[str, int]] = []
    for raw_line in lines:
        workload_match = WORKLOAD_PATTERN.search(raw_line)
        if workload_match is not None:
            workloads.append(
                {
                    "fixture_count": int(workload_match.group(1)),
                    "fixture_bytes": int(workload_match.group(2)),
                    "indexed_count": int(workload_match.group(3)),
                }
            )
        if "measured" not in raw_line.lower():
            continue
        average_match = AVERAGE_PATTERN.search(raw_line)
        if average_match is None:
            continue
        rsd_match = RSD_PATTERN.search(raw_line)
        measurements.append(
            {
                "line": raw_line.strip(),
                "average_seconds": float(average_match.group(1)),
                "relative_standard_deviation_percent": (
                    float(rsd_match.group(1)) if rsd_match else None
                ),
            }
        )

    fixture_count, fixture_bytes, fixture_sha256 = fixture_identity(
        args.fixture_root
    )
    observed_max = (
        max(float(item["average_seconds"]) for item in measurements)
        if measurements
        else None
    )
    observed_max_rsd = (
        max(
            float(item["relative_standard_deviation_percent"])
            for item in measurements
            if item["relative_standard_deviation_percent"] is not None
        )
        if any(
            item["relative_standard_deviation_percent"] is not None
            for item in measurements
        )
        else None
    )

    status = "passed"
    error = ""
    if args.build_exit_code != 0:
        status = "build_failure"
        error = f"Perf build exited with code {args.build_exit_code}"
    elif args.test_exit_code != 0:
        if any(pattern in log_text.lower() for pattern in INFRASTRUCTURE_PATTERNS):
            status = "infrastructure_failure"
        else:
            status = "test_failure"
        error = f"Perf test exited with code {args.test_exit_code}"
    elif observed_max is None:
        status = "test_failure"
        error = "No XCTest measured lines found; perf test may have skipped or failed"
    elif fixture_count != args.expected_fixture_count:
        status = "test_failure"
        error = (
            f"Fixture count {fixture_count} does not match expected "
            f"{args.expected_fixture_count}"
        )
    elif not workloads:
        status = "test_failure"
        error = "No ENGRAM_PERF_WORKLOAD evidence found"
    elif any(
        item["fixture_count"] != fixture_count
        or item["fixture_bytes"] != fixture_bytes
        or item["indexed_count"] != fixture_count
        for item in workloads
    ):
        status = "test_failure"
        error = "Perf test did not index the complete fixture workload"
    elif any(
        item["relative_standard_deviation_percent"] is None
        for item in measurements
    ):
        status = "noisy"
        error = "XCTest measurement is missing relative standard deviation"
    elif observed_max_rsd is not None and observed_max_rsd > args.max_rsd_percent:
        status = "noisy"
        error = (
            f"Performance RSD {observed_max_rsd:.3f}% exceeds noise budget "
            f"{args.max_rsd_percent:.3f}%"
        )
    elif observed_max > args.max_average_seconds:
        status = "regression"
        error = (
            f"Performance average {observed_max:.3f}s exceeds budget "
            f"{args.max_average_seconds:.3f}s"
        )

    workload = {
        "fixture_count": fixture_count,
        "fixture_bytes": fixture_bytes,
        "fixture_sha256": fixture_sha256,
        "expected_fixture_count": args.expected_fixture_count,
        "indexed_count": (
            workloads[0]["indexed_count"] if workloads else None
        ),
        "iterations_reported": len(workloads),
    }
    payload = {
        "workflow": "Perf",
        "metric": "Swift indexer generated-fixture elapsed time",
        "status": status,
        "passed": status == "passed",
        "error": error or None,
        "build_exit_code": args.build_exit_code,
        "test_exit_code": args.test_exit_code,
        "max_average_seconds": args.max_average_seconds,
        "max_relative_standard_deviation_percent": args.max_rsd_percent,
        "observed_max_average_seconds": observed_max,
        "observed_max_relative_standard_deviation_percent": observed_max_rsd,
        "baseline": {
            "id": args.baseline_id,
            "average_seconds": args.baseline_average_seconds,
        },
        "environment": {
            "git_sha": args.git_sha,
            "runner_name": args.runner_name,
            "runner_os": args.runner_os,
            "runner_arch": args.runner_arch,
            "xcode_version": args.xcode_version,
            "sdk_version": args.sdk_version,
        },
        "workload": workload,
        "measurements": measurements,
    }
    args.results.write_text(json.dumps(payload, indent=2) + "\n")

    if status != "passed":
        print(error, file=sys.stderr)
        return 1

    print(
        f"Performance gate passed: {observed_max:.3f}s <= "
        f"{args.max_average_seconds:.3f}s, RSD <= {args.max_rsd_percent:.3f}%"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

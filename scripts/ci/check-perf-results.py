#!/usr/bin/env python3
"""Extract XCTest measurements, persist evidence, and enforce a stable budget."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path


AVERAGE_PATTERN = re.compile(r"average:\s*([0-9.]+)")
RSD_PATTERN = re.compile(r"relative standard deviation:\s*([0-9.]+)%")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--max-average-seconds", required=True, type=float)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    budget = args.max_average_seconds
    if not math.isfinite(budget) or budget <= 0:
        print("Performance budget must be a positive finite number", file=sys.stderr)
        return 2

    lines = []
    if args.log.exists():
        lines = args.log.read_text(errors="replace").splitlines()

    measurements: list[dict[str, object]] = []
    for raw_line in lines:
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

    observed_max = (
        max(float(item["average_seconds"]) for item in measurements)
        if measurements
        else None
    )
    passed = observed_max is not None and observed_max <= budget
    payload = {
        "workflow": "Perf",
        "metric": "Swift indexer generated-fixture throughput",
        "max_average_seconds": budget,
        "observed_max_average_seconds": observed_max,
        "passed": passed,
        "measurements": measurements,
    }
    args.results.write_text(json.dumps(payload, indent=2) + "\n")

    if observed_max is None:
        print(
            "No XCTest measured lines found; perf test may have skipped or failed",
            file=sys.stderr,
        )
        return 1
    if observed_max > budget:
        print(
            f"Performance average {observed_max:.3f}s exceeds budget {budget:.3f}s",
            file=sys.stderr,
        )
        return 1

    print(f"Performance gate passed: {observed_max:.3f}s <= {budget:.3f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

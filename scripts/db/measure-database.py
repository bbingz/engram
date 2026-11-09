#!/usr/bin/env python3
"""Read-only lifecycle measurements; emits aggregate JSON, never transcript text."""

import argparse
from contextlib import closing
import json
import math
from pathlib import Path
import sqlite3
import sys
import time
from datetime import datetime, timezone


def measure(database, timeout):
    started = time.monotonic()
    # Do not use immutable=1: live WAL commits are part of the measurement.
    uri = Path(database).resolve().as_uri() + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True, timeout=min(timeout, 5))) as connection:
        connection.execute("PRAGMA query_only = ON")
        connection.set_progress_handler(
            lambda: time.monotonic() - started >= timeout, 1000
        )
        connection.execute("BEGIN")
        objects = dict(connection.execute("SELECT name, type FROM sqlite_schema"))
        owners = dict(connection.execute("SELECT name, tbl_name FROM sqlite_schema"))
        if objects.get("sessions") != "table":
            raise ValueError("required sessions table is missing")
        page_size = connection.execute("PRAGMA page_size").fetchone()[0]
        page_count = connection.execute("PRAGMA page_count").fetchone()[0]
        free_pages = connection.execute("PRAGMA freelist_count").fetchone()[0]
        storage = {"status": "available", "objects": []}
        try:
            storage["objects"] = [
                {"name": name, "table": owners.get(name, name),
                 "type": objects.get(name, "internal"), "bytes": size}
                for name, size in connection.execute(
                    "SELECT name, SUM(pgsize) FROM dbstat GROUP BY name ORDER BY name"
                )
            ]
            storage["fts_bytes"] = sum(
                item["bytes"] for item in storage["objects"]
                if item["table"] == "sessions_fts"
                or item["table"].startswith("sessions_fts_")
            )
            storage["fts_page_share"] = storage["fts_bytes"] / (page_size * page_count)
        except sqlite3.OperationalError as error:
            if str(error) != "no such table: dbstat":
                raise
            storage = {"status": "unavailable", "reason": "SQLite has no dbstat module"}

        tiers = [
            {"tier": tier, "sessions": count}
            for tier, count in connection.execute(
                "SELECT tier, COUNT(*) FROM sessions GROUP BY tier ORDER BY tier"
            )
        ]
        fts = {"status": "unavailable", "reason": "sessions_fts is missing"}
        if objects.get("sessions_fts") == "table":
            counts = list(connection.execute("""
                SELECT s.tier, s.id IS NULL AS orphan, COUNT(*)
                FROM sessions_fts f LEFT JOIN sessions s ON s.id = f.session_id
                GROUP BY s.tier, s.id IS NULL
                """))
            total = sum(row[2] for row in counts)
            fts = {"status": "available", "rows": total,
                   "orphan_rows": sum(count for _, orphan, count in counts if orphan)}
            by_tier = {tier: count for tier, orphan, count in counts if not orphan}
            for item in tiers:
                item["fts_rows"] = by_tier.get(item["tier"], 0)
                item["fts_row_share"] = item["fts_rows"] / total if total else 0

        histogram = {}
        missing = invalid = 0
        for score, count in connection.execute("""
            SELECT quality_score, COUNT(*) FROM sessions
            WHERE tier IS NULL OR tier != 'skip' GROUP BY quality_score
            """):
            if score is None:
                missing += count
            elif isinstance(score, int) and 0 <= score <= 100:
                histogram[score] = count
            else:
                invalid += count
        scored = sum(histogram.values())

        def percentile(percent):
            rank = math.ceil(scored * percent / 100)
            cumulative = 0
            for score in sorted(histogram):
                cumulative += histogram[score]
                if cumulative >= rank:
                    return score
            return None

        formula_version = None
        if objects.get("metadata") == "table":
            row = connection.execute(
                "SELECT value FROM metadata WHERE key = 'quality_score_formula_version'"
            ).fetchone()
            formula_version = row[0] if row else None
        result = {
            "schema_version": 1,
            "captured_at": datetime.now(timezone.utc).isoformat(),
            "sqlite_version": sqlite3.sqlite_version,
            "snapshot": "single read transaction, including committed WAL",
            "database": {"page_size": page_size, "page_count": page_count,
                         "logical_bytes": page_size * page_count, "free_pages": free_pages},
            "storage": storage,
            "sessions": {"total": sum(item["sessions"] for item in tiers), "tiers": tiers},
            "fts": fts,
            "quality_score": {
                "scope": "all non-skip sessions, including hidden and NULL tier",
                "formula_version": formula_version,
                "scored": scored, "missing": missing, "invalid": invalid,
                "min": min(histogram, default=None), "max": max(histogram, default=None),
                "mean": sum(score * count for score, count in histogram.items()) / scored if scored else None,
                "percentile_method": "nearest rank over valid integer scores 0..100",
                "percentiles": {f"p{p}": percentile(p) for p in [10, 33, 50, 67, 90]},
                "histogram": [{"score": score, "sessions": histogram[score]} for score in sorted(histogram)],
            },
        }
        connection.rollback()
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, help="Explicit SQLite path; no default user database")
    parser.add_argument("--timeout", type=float, default=30, help="Read budget in seconds (default: 30)")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a positive finite number")
    try:
        result = measure(args.database, args.timeout)
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"measurement failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

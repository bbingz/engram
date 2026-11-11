#!/usr/bin/env python3
"""Export central ledger metadata to stdout for the K5 read-only preview.

No token, network, migration, connection to a local-role index, or output file.
The sqlite3 CLI runs in a separate process with mode=ro and readonly_shm=1;
existing WAL sidecars are required so SQLite cannot repair them on open.
This snapshot is preview evidence, never a reclamation lease.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

MAX_ROWS = 250_000
DEFAULT_DATABASE = Path.home() / ".engram-shadow-core-20260911/hq/state/service-index/database/index.sqlite"


def regular(path):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_nlink != 1 or info.st_mode & 0o077 or path.resolve() != path):
        raise ValueError("unsafe_input")
    return (info.st_dev, info.st_ino)


def export(path):
    path = Path(os.path.abspath(path))
    identity = regular(path)
    with path.open("rb") as file:
        header = file.read(20)
    if len(header) != 20 or not header.startswith(b"SQLite format 3\x00"):
        raise ValueError("invalid_database")
    if header[18] == 2 or header[19] == 2:
        for suffix in ("-wal", "-shm"):
            regular(Path(str(path) + suffix))
    # The hard-coded schema belongs only to the central capture index. Running
    # against a local service index or an unknown schema fails with no JSON.
    sql = f"""
    SELECT p.publication_sha256 AS publicationSHA256,
           json_extract(CAST(p.canonical_bytes AS TEXT),'$.manifestSHA256') AS manifestSHA256,
           p.machine_id AS machineID, p.source_instance_id AS sourceInstanceID,
           p.collector_epoch AS collectorEpoch, p.sequence,
           l.status, l.failure_code AS failureCode,
           EXISTS(SELECT 1 FROM capture_ingest_generations g
             WHERE g.publication_sha256=p.publication_sha256 AND g.parser_revision=l.parser_revision
               AND g.machine_id=p.machine_id AND g.source_instance_id=p.source_instance_id
               AND g.collector_epoch=p.collector_epoch AND g.sequence=p.sequence
               AND g.normalized_message_count>0 AND length(g.normalized_messages_json)>0) AS hasRetainedGeneration
    FROM capture_ingest_publications p JOIN capture_ingest_ledger l
      ON l.publication_sha256=p.publication_sha256
    WHERE l.parser_revision='swift-capture-v1'
    ORDER BY p.publication_sha256 LIMIT {MAX_ROWS + 1};
    """
    uri = path.as_uri() + "?mode=ro&readonly_shm=1"
    result = subprocess.run(["/usr/bin/sqlite3", "-batch", "-readonly", "-json", uri, sql],
                            capture_output=True, check=True, timeout=120)
    if regular(path) != identity or len(result.stdout) > 256 * 1024 * 1024:
        raise ValueError("changed_or_oversize_input")
    rows = json.loads(result.stdout or b"[]")
    if len(rows) > MAX_ROWS or len({r["publicationSHA256"] for r in rows}) != len(rows):
        raise ValueError("incomplete_or_duplicate_rows")
    for row in rows:
        row["hasRetainedGeneration"] = bool(row["hasRetainedGeneration"])
    return {"schemaVersion": 1, "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "parserRevision": "swift-capture-v1", "publications": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, default=DEFAULT_DATABASE)
    args = parser.parse_args()
    try:
        result = export(args.database)
    except (OSError, ValueError, subprocess.SubprocessError, KeyError, TypeError):
        print("spool-gc-central-export: read_only_export_failed", file=sys.stderr)
        return 1
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

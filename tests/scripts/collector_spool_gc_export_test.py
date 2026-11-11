"""Synthetic central export: stdout only, no writable SQLite/sidecar repair."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/collector-spool-gc-central-export.py"


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.db = self.root / "central.sqlite"

    def tearDown(self):
        self.temp.cleanup()

    def seed(self, wal=False):
        c = sqlite3.connect(self.db)
        c.executescript("""
        CREATE TABLE capture_ingest_publications(publication_sha256 TEXT PRIMARY KEY, canonical_bytes BLOB,
          machine_id TEXT, source_instance_id TEXT, collector_epoch TEXT, sequence INTEGER);
        CREATE TABLE capture_ingest_ledger(publication_sha256 TEXT, parser_revision TEXT, status TEXT, failure_code TEXT);
        CREATE TABLE capture_ingest_generations(publication_sha256 TEXT,parser_revision TEXT,machine_id TEXT,
          source_instance_id TEXT,collector_epoch TEXT,sequence INTEGER,normalized_message_count INTEGER,
          normalized_messages_json BLOB);
        """)
        envelope = json.dumps({"manifestSHA256": "b" * 64}).encode()
        c.execute("INSERT INTO capture_ingest_publications VALUES (?,?,?,?,?,?)", ("a" * 64, envelope, "machine", "instance", "epoch", 1))
        c.execute("INSERT INTO capture_ingest_ledger VALUES (?,?,?,NULL)", ("a" * 64, "swift-capture-v1", "index_ready"))
        c.execute("INSERT INTO capture_ingest_generations VALUES (?,?,?,?,?,?,?,?)", ("a" * 64, "swift-capture-v1", "machine", "instance", "epoch", 1, 1, b"[{}]"))
        c.commit()
        if wal:
            c.execute("PRAGMA journal_mode=WAL")
            c.execute("UPDATE capture_ingest_ledger SET status='parsed'")
            c.commit()
        for p in self.root.iterdir():
            p.chmod(0o600)
        return c

    def snapshot(self):
        return {p.name: (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode) for p in self.root.iterdir()}

    def run_export(self, *args):
        return subprocess.run(["python3", "-B", str(SCRIPT), "--database", str(self.db), *args],
                              capture_output=True, text=True, timeout=15)

    def test_export_retained_generation_without_any_write(self):
        self.seed().close()
        before = self.snapshot()
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        doc = json.loads(result.stdout)
        self.assertEqual(doc["publications"][0]["hasRetainedGeneration"], True)
        self.assertEqual(doc["publications"][0]["status"], "index_ready")
        self.assertNotIn("normalized_messages", result.stdout)
        self.assertEqual(self.snapshot(), before)

    def test_wal_reads_committed_state_without_sidecar_changes(self):
        writer = self.seed(wal=True)
        try:
            before = self.snapshot()
            result = self.run_export()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["publications"][0]["status"], "parsed")
            self.assertEqual(self.snapshot(), before)
        finally:
            writer.close()

    def test_missing_file_never_created(self):
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.db.exists())

    def test_missing_wal_sidecars_refuses_repair(self):
        self.seed().close()
        data = bytearray(self.db.read_bytes()); data[18] = data[19] = 2
        self.db.write_bytes(data)
        before = self.snapshot()
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.snapshot(), before)

    def test_unknown_schema_fails_without_output_or_migration(self):
        connection = sqlite3.connect(self.db)
        connection.execute("CREATE TABLE unrelated(value TEXT)")
        connection.close()
        self.db.chmod(0o600)
        before = self.snapshot()
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.snapshot(), before)

    def test_symlink_fails_without_output(self):
        self.seed().close()
        target = self.root / "real.sqlite"
        self.db.rename(target); self.db.symlink_to(target)
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()

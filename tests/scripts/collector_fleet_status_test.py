"""Read-only fleet probe and atomic snapshot contract tests."""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("fleet", ROOT / "scripts/collector-fleet-status.py")
fleet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet)


class FleetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.base.chmod(0o700)

    def tearDown(self):
        self.temp.cleanup()

    def test_inventory_counts_are_files_not_sessions_and_keep_cooling_dirty(self):
        db = self.base / "inventory.sqlite"
        with sqlite3.connect(db) as c:
            c.executescript("""
            CREATE TABLE collector_metadata(key TEXT,value TEXT);
            INSERT INTO collector_metadata VALUES('machine_id','11111111-2222-3333-4444-555555555555');
            CREATE TABLE collector_roots(root_id TEXT,source TEXT,root_path TEXT,requested_revision INT,
              completed_revision INT,active_scan_id TEXT,last_scan_failure TEXT,event_epoch TEXT);
            INSERT INTO collector_roots VALUES('root','cursor','/not-present',2,1,'scan',NULL,NULL);
            CREATE TABLE collector_locators(root_id TEXT,last_capture_id TEXT,dirty_revision INT,
              acknowledged_revision INT,last_error TEXT);
            INSERT INTO collector_locators VALUES('root','capture',3,2,'recaptureCooldown');
            INSERT INTO collector_locators VALUES('root',NULL,1,0,'unavailable');
            CREATE TABLE collector_publications(publication_digest TEXT,root_id TEXT,relative_path TEXT);
            INSERT INTO collector_publications VALUES('one','root','one');
            CREATE TABLE collector_publication_replicas(publication_digest TEXT,replica_id TEXT,state TEXT,last_error TEXT);
            INSERT INTO collector_publication_replicas VALUES('one','hq','pending','privacyWithheld');
            INSERT INTO collector_publication_replicas VALUES('one','m1','inflight',NULL);
            """)
        result = fleet.inventory_status(db)
        self.assertEqual(result["capture"]["capturedLocators"], 1)
        self.assertEqual(result["capture"]["dirtyLocators"], 2)
        self.assertEqual(result["capture"]["coolingLocators"], 1)
        self.assertNotIn("sessions", result["capture"])
        self.assertEqual(result["roots"][0]["scanLag"], 1)
        hq = next(r for r in result["replicas"] if r["id"] == "hq")
        self.assertEqual(hq["withheld"], 1)
        self.assertEqual(hq["pending"], 0)
        self.assertEqual(next(r for r in result["replicas"] if r["id"] == "m1")["inflight"], 1)
        # The probe opened the existing DB read-only, and never creates a missing DB.
        with self.assertRaises(sqlite3.OperationalError):
            fleet.inventory_status(self.base / "absent.sqlite")
        self.assertFalse((self.base / "absent.sqlite").exists())

    def test_failed_remote_probe_never_emits_target_or_stderr(self):
        target = {"id": "remote", "label": "Remote", "role": "collector", "target": "private-host"}
        with patch.object(fleet.subprocess, "run", side_effect=TimeoutError("secret remote path")):
            result = fleet.sample_target(target)
        self.assertEqual(result["status"], "unreachable")
        self.assertIsNone(result["observedAt"])
        serialized = json.dumps(result)
        self.assertNotIn("private-host", serialized)
        self.assertNotIn("secret", serialized)
        self.assertIsNone(result["capture"])

    def test_atomic_output_is_private_and_refuses_symlink(self):
        path = self.base / "status.json"
        fleet.atomic_write(path, {"schemaVersion": 1})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(path.read_text()), {"schemaVersion": 1})
        link = self.base / "alias.json"
        link.symlink_to(path)
        with self.assertRaises(ValueError):
            fleet.atomic_write(link, {"bad": True})
        self.assertEqual(json.loads(path.read_text()), {"schemaVersion": 1})

    def test_config_rejects_shell_options_duplicate_ids_and_overwide_scope(self):
        for targets in [
            [{"id": "same", "label": "A", "role": "collector"}] * 2,
            [{"id": "bad", "label": "A", "role": "collector", "target": "-oProxyCommand=oops"}],
            [{"id": "bad", "label": "A", "role": "collector", "target": "host;echo oops"}],
            [{"id": "bad", "label": "A", "role": "collector", "storageRoots": [{"name": "all", "path": "/"}]}],
        ]:
            with self.assertRaises(ValueError):
                fleet.validate_config({"machines": targets})

    def test_process_revision_comes_from_loaded_job_not_an_updated_plist(self):
        import types
        base = self.base; (base/'bin').mkdir()
        binary = base/'bin/EngramCollector'
        (base/'BUILD-METADATA.json').write_text(json.dumps({'sourceRevision':'a'*40}))
        printed = types.SimpleNamespace(returncode=0, stdout=f'state = running\nprogram = {binary}\npid = 42\n')
        with patch.object(fleet.subprocess, 'run', return_value=printed):
            process = fleet.process_status([{'name':'Collector','label':'com.engram.collector'}])[0]
        self.assertEqual(process['state'],'running')
        self.assertEqual(process['pid'],42)
        self.assertEqual(process['revision'],'a'*40)

    def test_central_counts_keep_session_visibility_and_ledger_units_separate(self):
        p = self.base/'index.sqlite'
        mid = '11111111-1111-4111-8111-111111111111'
        with sqlite3.connect(p) as c:
            c.executescript('''CREATE TABLE sessions(origin TEXT,hidden_at TEXT,tier TEXT);
                CREATE TABLE capture_ingest_publications(machine_id TEXT,publication_sha256 TEXT);
                CREATE TABLE capture_ingest_ledger(publication_sha256 TEXT,status TEXT);
                CREATE TABLE session_index_jobs(job_kind TEXT,status TEXT);''')
            c.executemany('INSERT INTO sessions VALUES(?,?,?)',[
                ('capture-v1.'+mid+'.source',None,'full'),('capture-v1.'+mid+'.source',None,'skip'),
                ('capture-v1.'+mid+'.source','yesterday','full'),('legacy',None,'full')])
            c.executemany('INSERT INTO capture_ingest_publications VALUES(?,?)',[(mid,'a'),(mid,'b')])
            c.executemany('INSERT INTO capture_ingest_ledger VALUES(?,?)',[('a','index_ready'),('b','quarantined')])
            c.executemany('INSERT INTO session_index_jobs VALUES(?,?)',[('fts','pending'),('fts','failed_permanent'),('semantic','pending')])
        result = fleet.central_status(p); row = result['machines'][0]
        self.assertEqual((row['sessions'],row['visibleSessions'],row['publications']),(3,1,2))
        self.assertEqual((row['indexReady'],row['quarantined'],row['pending']),(1,1,0))
        self.assertEqual((result['ftsPending'],result['ftsFailed']),(1,1))

    def test_missing_collector_state_is_unknown_not_zero(self):
        with patch.object(fleet, "process_status", return_value=[]):
            result = fleet.local_probe({"id": "local", "label": "Local", "role": "collector",
                "collectorSpool": str(self.base / "missing"), "diskPath": str(self.base)})
        self.assertIsNone(result["capture"])
        self.assertEqual(result["errors"], ["inventoryUnavailable"])
        self.assertEqual(result["roots"], [])
        self.assertNotIn(str(self.base), json.dumps(result))


if __name__ == "__main__":
    unittest.main()

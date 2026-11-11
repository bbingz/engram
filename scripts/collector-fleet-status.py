#!/usr/bin/env python3
"""Opt-in, read-only macOS fleet observation exporter for the Web dashboard.

Run out of band, never from a Web request. Reads only operator-configured state
paths; no credentials, session contents, source paths, or SSH errors are exported.
Python is an operations tool, not a product server or app startup dependency.
"""
import argparse
import concurrent.futures
import ctypes
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

MAX_BYTES = 1024 * 1024
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")


def readonly(path):
    # mode=ro must not silently create an empty DB when a path is misconfigured.
    return sqlite3.connect(Path(path).as_uri() + "?mode=ro", uri=True, timeout=5)


def epoch_status(path, stored):
    """Compare the live device UUID, not old stderr lines from a prior process."""
    if sys.platform != "darwin":
        return "unknown"
    try:
        dev = os.stat(path).st_dev
        cs = ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/CoreServices')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cs.FSEventsCopyUUIDForDevice.argtypes = [ctypes.c_int32]
        cs.FSEventsCopyUUIDForDevice.restype = ctypes.c_void_p
        cf.CFUUIDCreateString.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cf.CFUUIDCreateString.restype = ctypes.c_void_p
        cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
        cf.CFStringGetCString.restype = ctypes.c_bool
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        value = cs.FSEventsCopyUUIDForDevice(dev)
        if not value:
            return "unknown"
        text = None
        try:
            text = cf.CFUUIDCreateString(None, value)
            buf = ctypes.create_string_buffer(64)
            if not text or not cf.CFStringGetCString(text, buf, len(buf), 0x08000100):
                return "unknown"
            live = buf.value.decode("ascii")
        finally:
            if text:
                cf.CFRelease(text)
            cf.CFRelease(value)
        if not stored:
            return "noCheckpoint"
        return "match" if stored.removeprefix("fsevents-device-v1:").lower() == live.lower() else "mismatch"
    except (OSError, ValueError):
        return "unknown"


def inventory_status(path):
    with readonly(path) as c:
        machine = c.execute("SELECT value FROM collector_metadata WHERE key='machine_id'").fetchone()
        roots = []
        for rid, source, root_path, req, done, scan, failure, epoch in c.execute("""
            SELECT root_id,source,root_path,requested_revision,completed_revision,
                   active_scan_id,last_scan_failure,event_epoch FROM collector_roots ORDER BY root_id
        """):
            n, captured, dirty, cooling, unavailable = c.execute("""
                SELECT count(*),coalesce(sum(last_capture_id IS NOT NULL),0),
                  coalesce(sum(dirty_revision>acknowledged_revision),0),
                  coalesce(sum(dirty_revision>acknowledged_revision AND last_error='recaptureCooldown'),0),
                  coalesce(sum(dirty_revision>acknowledged_revision AND last_error='unavailable'),0)
                FROM collector_locators WHERE root_id=?
            """, (rid,)).fetchone()
            roots.append(dict(id=rid, source=source, locators=n, captured=captured, dirty=dirty,
                cooling=cooling, unavailable=unavailable, scanning=scan is not None,
                scanLag=max(0, req-done), scanFailed=failure is not None,
                epochStatus=epoch_status(root_path, epoch)))
        replicas = {}
        for rid, state, error, n in c.execute("""
            SELECT replica_id,state,last_error,count(*) FROM collector_publication_replicas GROUP BY 1,2,3
        """):
            r = replicas.setdefault(rid, dict(id=rid, pending=0, inflight=0, acknowledged=0, withheld=0, failed=0))
            if error == 'privacyWithheld':
                r['withheld'] += n
            else:
                if state in ('pending', 'inflight', 'acknowledged'):
                    r[state] += n
                if error:
                    r['failed'] += n  # Overlaps pending/inflight; not another queue.
        capture = dict(publications=c.execute("SELECT count(*) FROM collector_publications").fetchone()[0],
            capturedLocators=sum(r['captured'] for r in roots), dirtyLocators=sum(r['dirty'] for r in roots),
            coolingLocators=sum(r['cooling'] for r in roots), unavailableLocators=sum(r['unavailable'] for r in roots))
        return dict(machineId=machine[0] if machine else None, capture=capture,
                    replicas=list(replicas.values()), roots=roots)


def process_status(jobs):
    result = []
    for job in jobs:
        state, pid, revision = 'unknown', None, None
        try:
            p = subprocess.run(['launchctl','print',f'gui/{os.getuid()}/{job["label"]}'],
                capture_output=True, text=True, timeout=5)
            if p.returncode:
                state = 'stopped'
            else:
                running = re.search(r'^\s*state = running\s*$', p.stdout, re.M)
                m = re.search(r'^\s*pid = (\d+)\s*$', p.stdout, re.M)
                state, pid = ('running' if running else 'stopped'), int(m[1]) if m else None
                # Use the loaded job, not a plist that may have been edited without a restart.
                # Never copy argv/environment or program paths into the exported snapshot.
                program = re.search(r'^\s*program = (/[^\r\n]+)$', p.stdout, re.M)
                if program:
                    binary = Path(program[1])
                    metadata = json.loads((binary.parents[1]/'BUILD-METADATA.json').read_text())
                    value = metadata.get('sourceRevision', '') if isinstance(metadata, dict) else ''
                    revision = value if isinstance(value, str) and re.fullmatch(r'[0-9a-f]{40}', value) else None
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            pass
        result.append(dict(name=job['name'], state=state, pid=pid, revision=revision))
    return result


def local_probe(target):
    result = dict(observedAt=int(time.time()), status='ok', machineId=None, processes=process_status(target.get('jobs', [])),
                  disk=None, storage=[], capture=None, roots=[], replicas=[], errors=[])
    try:
        usage = shutil.disk_usage(target.get('diskPath', str(Path.home())))
        result['disk'] = dict(totalBytes=usage.total, freeBytes=usage.free)
    except OSError:
        result['errors'].append('diskUnavailable')
    spool = target.get('collectorSpool')
    if spool:
        try:
            result.update(inventory_status(Path(spool)/'inventory/inventory.sqlite'))
        except (OSError, sqlite3.Error):
            result['errors'].append('inventoryUnavailable')
        if result['capture'] is not None:
            try:
                with readonly(Path(spool)/'capture/archive.sqlite') as c:
                    stamp = c.execute('SELECT max(captured_at) FROM archive_captures').fetchone()[0]
                    result['capture']['lastCaptureAt'] = int(datetime.datetime.fromisoformat(stamp.replace('Z','+00:00')).timestamp()) if stamp else None
            except (OSError, sqlite3.Error, ValueError):
                result['errors'].append('captureCatalogUnavailable')
    # Explicitly configured directories only; no home/volume traversal by default.
    for root in target.get('storageRoots', []):
        used = None
        try:
            p = subprocess.run(['/usr/bin/du','-sk',root['path']],capture_output=True,text=True,timeout=15)
            if p.returncode == 0:
                used = int(p.stdout.split()[0]) * 1024
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            pass
        result['storage'].append(dict(name=root['name'], usedBytes=used, observedAt=int(time.time())))
    return result


def sample_target(target):
    base = dict(id=target['id'],label=target['label'],role=target['role'],lastAttemptAt=int(time.time()))
    try:
        if target.get('target'):
            args = ['python3','-I','-','--probe',json.dumps(target,separators=(',',':'))]
            p = subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ServerAliveInterval=5',
                '-o','ServerAliveCountMax=2','-o','LogLevel=ERROR',target['target'],shlex.join(args)],
                input=Path(__file__).read_text(),capture_output=True,text=True,timeout=90)
            if p.returncode or len(p.stdout.encode()) > MAX_BYTES:
                raise ValueError('probe failed')
            observation = json.loads(p.stdout)
        else:
            observation = local_probe(target)
        base.update(observation)
    except Exception:
        # Never expose SSH stderr, paths, or partial stdout as a healthy sample.
        base.update(observedAt=None,status='unreachable',machineId=None,processes=[],disk=None,storage=[],
                    capture=None,roots=[],replicas=[],errors=['probeUnavailable'])
    return base


def central_status(path):
    with readonly(path) as c:
        machines = {}
        def machine(mid):
            return machines.setdefault(mid, dict(machineId=mid,sessions=0,visibleSessions=0,publications=0,
                pending=0,processing=0,parsed=0,indexReady=0,retryable=0,quarantined=0))
        for mid, total, visible in c.execute("""
            SELECT substr(origin,12,36),count(*),sum(hidden_at IS NULL AND coalesce(tier,'')!='skip')
            FROM sessions WHERE origin LIKE 'capture-v1.%' GROUP BY 1
        """):
            if UUID.fullmatch(mid):
                machine(mid).update(sessions=total,visibleSessions=visible)
        for mid, n in c.execute('SELECT machine_id,count(*) FROM capture_ingest_publications GROUP BY 1'):
            machine(mid)['publications'] = n
        keys = {'pending':'pending','processing':'processing','parsed':'parsed','index_ready':'indexReady',
                'failed_retryable':'retryable','quarantined':'quarantined'}
        for mid, state, n in c.execute("""
            SELECT p.machine_id,l.status,count(*) FROM capture_ingest_publications p
            JOIN capture_ingest_ledger l USING(publication_sha256) GROUP BY 1,2
        """):
            if state in keys:
                machine(mid)[keys[state]] = n
        fts = dict(c.execute("SELECT status,count(*) FROM session_index_jobs WHERE job_kind='fts' GROUP BY 1"))
        return dict(observedAt=int(time.time()),machines=list(machines.values()),
                    ftsPending=fts.get('pending',0)+fts.get('failed_retryable',0)+fts.get('processing',0),
                    ftsFailed=fts.get('failed_permanent',0))


def safe_path(value):
    p = Path(value)
    if not p.is_absolute() or '..' in p.parts or str(p) in ('/', str(Path.home())):
        raise ValueError('explicit bounded absolute state path required')


def validate_config(config):
    targets = config.get('machines', [])
    if not 1 <= len(targets) <= 64:
        raise ValueError('1...64 machines required')
    seen = set()
    for t in targets:
        if not IDENTIFIER.fullmatch(t['id']) or t['id'] in seen or not 1 <= len(t['label']) <= 80:
            raise ValueError('invalid machine identity')
        seen.add(t['id'])
        if t['role'] not in ('collector','index','replica'):
            raise ValueError('invalid role')
        ssh = t.get('target')
        if ssh and (ssh.startswith('-') or not re.fullmatch(r'[A-Za-z0-9_.@:\[\]-]{1,254}',ssh)):
            raise ValueError('invalid SSH target')
        for key in ('collectorSpool','diskPath'):
            if key in t:
                safe_path(t[key])
        if len(t.get('jobs',[])) > 16 or len(t.get('storageRoots',[])) > 16:
            raise ValueError('too many probe paths')
        for job in t.get('jobs',[]):
            if not IDENTIFIER.fullmatch(job['label']) or not 1 <= len(job['name']) <= 80:
                raise ValueError('invalid job')
        for root in t.get('storageRoots',[]):
            safe_path(root['path'])
            if not 1 <= len(root['name']) <= 80:
                raise ValueError('invalid storage label')
    if config.get('centralDatabase'):
        safe_path(config['centralDatabase'])


def private_read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as f:
        info = os.fstat(f.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or stat.S_IMODE(info.st_mode)!=0o600:
            raise ValueError('configuration must be an owner-only regular file')
        data = f.read(MAX_BYTES+1)
        if len(data)>MAX_BYTES:
            raise ValueError('configuration too large')
        return json.loads(data)


def atomic_write(path, value):
    path = Path(path).absolute()
    parent = path.parent
    info = parent.stat()
    if parent.resolve()!=parent or info.st_uid!=os.getuid() or info.st_mode & 0o022:
        raise ValueError('unsafe output directory')
    if path.is_symlink() or (path.exists() and (not path.is_file() or path.stat().st_nlink!=1)):
        raise ValueError('unsafe output file')
    data = json.dumps(value,separators=(',',':')).encode()
    if len(data)>MAX_BYTES:
        raise ValueError('snapshot too large')
    fd, name = tempfile.mkstemp(prefix='.fleet-',dir=parent)
    try:
        with os.fdopen(fd,'wb') as f:
            os.fchmod(f.fileno(),0o600)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name,path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--config')
    ap.add_argument('--output')
    ap.add_argument('--watch',action='store_true')
    ap.add_argument('--interval',type=int,default=300)
    ap.add_argument('--probe',help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.probe:
        print(json.dumps(local_probe(json.loads(args.probe))))
        return
    if not args.config or not args.output or not 60 <= args.interval <= 3600:
        ap.error('--config, --output and an interval in 60...3600 are required')
    while True:
        config = private_read(args.config)
        validate_config(config)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            machines = list(pool.map(sample_target,config['machines']))
        snapshot = dict(schemaVersion=1,generatedAt=int(time.time()),machines=machines,central=None)
        if config.get('centralDatabase'):
            try:
                snapshot['central'] = central_status(config['centralDatabase'])
            except (OSError,sqlite3.Error):
                pass  # Explicit null, never healthy-looking zero totals.
        atomic_write(args.output,snapshot)
        print('fleet snapshot written; machines=%d' % len(machines),flush=True)
        if not args.watch:
            break
        time.sleep(args.interval)


if __name__=='__main__':
    main()

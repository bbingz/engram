"""Activate a web-parity-20260913 HQ package for one launchd role.

usage: activate-web-parity-role.py <service-index|remote-server> <expected-binary-sha256>

Swaps only ProgramArguments[0] of the existing owner-only LaunchAgent to the new
package binary (and, for remote-server, adds ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL
from persistent/editor-credential.txt when absent), restarts the job, verifies
the new process is stable and serving, and records a receipt. On any failure the
previous plist is restored and the old job relaunched. Data directories are
never touched.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

NAME = os.environ.get("WEB_PARITY_PACKAGE", "web-parity-20260913")
role = sys.argv[1]
assert role in ["remote-server", "service-index"]
expected_binary = sys.argv[2]
root = pathlib.Path("/Users/bing/.engram-shadow-core-20260911/hq")
product = {"remote-server": "EngramRemoteServer", "service-index": "EngramService"}[role]
label = {"remote-server": "com.engram.capture-core.receiver", "service-index": "com.engram.service-index"}[role]
target = root / f"{role}-{NAME}"
new = target / "bin" / product
persistent = root / "state" / role / "persistent"
job = pathlib.Path("/Users/bing/Library/LaunchAgents") / (label + ".plist")


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


assert digest(new) == expected_binary, "binary hash mismatch"
for line in (target / "SHA256SUMS").read_text().splitlines():
    expected, name = line.split("  ", 1)
    path = target / name
    assert path.resolve().is_relative_to(target.resolve()) and digest(path) == expected, "package integrity mismatch"
raw = job.read_bytes()
config = plistlib.loads(raw)
assert config["Label"] == label
assert digest(job) == json.loads((persistent / "install.json").read_text())["jobSHA256"], "job changed since last install receipt"
old = pathlib.Path(config["ProgramArguments"][0])
assert old.is_relative_to(root) and old.name == product
domain = "gui/" + str(os.getuid())


def process():
    r = subprocess.run(["launchctl", "print", domain + "/" + label], capture_output=True, text=True)
    m = re.search(r"^\s*pid = (\d+)", r.stdout, re.M)
    pid = int(m[1]) if m else None
    exe = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip() if pid else ""
    return pid, exe


oldpid, exe = process()
assert exe == str(old), f"old process mismatch: {exe!r} != {old}"
backup = persistent / f"{NAME}-job-before.plist"
assert not backup.exists(), backup
backup.write_bytes(raw)
backup.chmod(0o600)
config["ProgramArguments"][0] = str(new)
editor_added = False
if role == "remote-server" and "ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL" not in config["EnvironmentVariables"]:
    cred_file = persistent / "editor-credential.txt"
    credential = cred_file.read_text().strip()
    assert len(credential) >= 32, "editor credential too short"
    assert credential != config["EnvironmentVariables"].get("ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL"), "editor must differ from viewer"
    config["EnvironmentVariables"]["ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL"] = credential
    editor_added = True


def atomic(path, data):
    tmp = path.with_suffix(path.suffix + f".{NAME}-new")
    assert not tmp.exists()
    tmp.write_bytes(data)
    tmp.chmod(0o600)
    os.replace(tmp, path)


def launch():
    r = subprocess.run(["launchctl", "bootstrap", domain, str(job)], capture_output=True, text=True)
    assert r.returncode == 0, "bootstrap failed: " + r.stderr


result = {
    "role": role, "host": "hq", "label": label, "oldPID": oldpid, "oldExecutable": str(old),
    "executable": str(new), "binarySHA256": digest(new), "rollbackJob": str(backup), "editorCredentialAdded": editor_added,
}
try:
    r = subprocess.run(["launchctl", "bootout", domain, str(job)], capture_output=True, text=True)
    assert r.returncode == 0, "bootout failed: " + r.stderr
    atomic(job, plistlib.dumps(config))
    launch()
    for _ in range(120):
        pid, exe = process()
        if exe == str(new):
            break
        time.sleep(0.25)
    else:
        raise RuntimeError("new process did not start")
    time.sleep(15)
    stablepid, stableexe = process()
    assert stablepid == pid and stableexe == str(new), "process failed 15s stability"
    if role == "remote-server":
        # The Web boundary requires the published origin Host header (WebRequestBoundary.validateHost);
        # loopback probes must present it or they are rejected with 403 regardless of server health.
        host = config["EnvironmentVariables"]["ENGRAM_REMOTE_WEB_ORIGIN"].split("://", 1)[1]
        deadline = time.monotonic() + 90
        status = None
        body = ""
        while time.monotonic() < deadline:
            try:
                req = urllib.request.Request("http://127.0.0.1:18787/web/", headers={"Host": host})
                with urllib.request.urlopen(req, timeout=5) as resp:
                    status = resp.status
                    body = resp.read(4096).decode("utf-8", "replace")
                break
            except urllib.error.HTTPError as e:
                status = e.code
                break
            except Exception:
                time.sleep(1)
        assert status == 200 and "Engram" in body, f"web not serving: {status}"
        req = urllib.request.Request("http://127.0.0.1:18787/web/api/overview", headers={"Host": host, "X-Engram-Web": "1"})
        try:
            urllib.request.urlopen(req, timeout=5)
            raise AssertionError("unauthenticated overview must not be 200")
        except urllib.error.HTTPError as e:
            assert e.code in (401, 403), e.code
            result["unauthenticatedOverview"] = e.code
        result["webRootStatus"] = status
    else:
        sock = root / "state/service-index/ipc/service.sock"
        deadline = time.monotonic() + 90
        while not sock.exists() and time.monotonic() < deadline:
            assert process() == (pid, str(new)), "new service exited during startup"
            time.sleep(1)
        assert sock.exists(), "service socket missing"
        result["socket"] = str(sock)
    loaded = subprocess.check_output(["lsof", "-p", str(pid), "-Fn"], text=True).splitlines()
    frameworks = {}
    for fw in sorted((target / "Frameworks").glob("*.framework")):
        f = fw / "Versions/A" / fw.stem
        if f.exists():
            assert "n" + str(f) in loaded, f"framework not loaded from package: {f}"
            frameworks[fw.stem] = digest(f)
    result.update(pid=pid, passed=True, checkedAt=time.time(), stableSeconds=15, loadedFrameworks=frameworks)
    installpath = persistent / "install.json"
    install = json.loads(installpath.read_text())
    install.update(executable=str(new), jobSHA256=digest(job), previousExecutable=str(old), rollbackJob=str(backup))
    atomic(installpath, (json.dumps(install, indent=2) + "\n").encode())
except Exception:
    subprocess.run(["launchctl", "bootout", domain + "/" + label], capture_output=True, text=True)
    atomic(job, raw)
    launch()
    result.update(passed=False, rolledBack=True)
    raise
finally:
    receipt = persistent / f"{NAME}-activation.json"
    atomic(receipt, (json.dumps(result, indent=2) + "\n").encode())
print(json.dumps(result))

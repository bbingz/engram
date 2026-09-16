"""Build and package the web-parity-20260913 HQ candidates.

Builds Release arm64 EngramService (service-index role) and EngramRemoteServer
(remote-server role) from the current dirty worktree, packages them with the
repository packaging scripts, and writes SOURCE-PROVENANCE.json plus SHA256SUMS
into the private HQ shadow root. Nothing is activated here.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys

NAME = os.environ.get("WEB_PARITY_PACKAGE", "web-parity-20260913")
repo = pathlib.Path(__file__).resolve().parents[2]
base = pathlib.Path(__file__).resolve().parent
os.chdir(repo)
dd = repo / "output/collector-goal-20260908/test-home/Library/Developer/Xcode/DerivedData/Engram-hhoanydntycvdyhdxwwncrztqpql"
shadow = pathlib.Path("/Users/bing/.engram-shadow-core-20260911/hq")
assert dd.is_dir(), dd
assert shadow.is_dir(), shadow


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def sources():
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "macos"],
        text=True,
    ).split("\0")
    return {n: digest(repo / n) for n in sorted(set(names)) if n and (repo / n).is_file()}


before = sources()
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
checks = []
roles = [("EngramService", "service", "service-index"), ("EngramRemoteServer", "remote-server", "remote-server")]
only = sys.argv[1:]
for product, script, role in roles:
    if only and role not in only:
        continue
    bundle = shadow / f"{role}-{NAME}"
    assert not bundle.exists(), f"target exists: {bundle}"
    argv = [
        "xcodebuild", "build", "-project", "macos/Engram.xcodeproj", "-scheme", product,
        "-configuration", "Release", "-destination", "platform=macOS", "CODE_SIGNING_ALLOWED=NO",
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "-derivedDataPath", str(dd),
    ]
    with (base / f"{NAME}-{product}-build.log").open("w") as log:
        r = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT)
    checks.append({"product": product, "role": role, "buildExit": r.returncode})
    assert r.returncode == 0, f"build failed for {product}; see {NAME}-{product}-build.log"
    assert sources() == before, "Sources changed during build"
    bundle.mkdir(mode=0o700)
    argv = [
        "bash", f"macos/scripts/package-{script}.sh", "--derived-data", str(dd), "--configuration", "Release",
        "--arch", "arm64", "--source-revision", revision, "--output", str(bundle),
    ]
    with (base / f"{NAME}-{product}-package.log").open("w") as log:
        r = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT)
    assert r.returncode == 0, f"package failed for {product}; see {NAME}-{product}-package.log"
    (bundle / "SOURCE-PROVENANCE.json").write_text(json.dumps({
        "sourceState": "dirty-worktree", "baseRevision": revision, "sourceFiles": before,
        "sourceStableAcrossBuild": True,
    }, indent=2) + "\n")
    metadata = bundle / "BUILD-METADATA.json"
    v = json.loads(metadata.read_text())
    v.update(sourceState="dirty-worktree", sourceRevisionMeaning="base-only", sourceProvenanceFile="SOURCE-PROVENANCE.json")
    metadata.write_text(json.dumps(v, indent=2) + "\n")
    paths = sorted(f for f in bundle.rglob("*") if f.is_file() and not f.is_symlink() and f.name != "SHA256SUMS")
    (bundle / "SHA256SUMS").write_text("".join(digest(f) + "  " + str(f.relative_to(bundle)) + "\n" for f in paths))
    r = subprocess.run(["bash", f"macos/scripts/package-{script}.sh", "--verify-only", str(bundle)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    checks[-1].update(packageVerified=True, package=str(bundle), binarySHA256=digest(bundle / "bin" / product))
    (base / f"{NAME}-build-result.json").write_text(json.dumps({"checks": checks, "sourceStable": sources() == before, "baseRevision": revision}, indent=2) + "\n")
    print(product, "built and package verified ->", bundle, flush=True)

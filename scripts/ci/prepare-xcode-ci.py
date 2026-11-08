#!/usr/bin/env python3
"""CI-only Xcode workspace tweaks applied after scripts/check-xcodeproj-drift.sh.

Run from the repository root. Every tweak is reverted by
`git checkout -- macos/Engram.xcodeproj` at the end of the job step.

  --strip-hummingbird  Drop the Hummingbird package (and its 23 transitive
                       packages) for jobs whose schemes never link it, so
                       package resolution only loads GRDB + ArgumentParser.
  --mcp-in-engram-scheme
                       Swap EngramUITests for EngramMCPTests in the Engram
                       scheme so one `xcodebuild test` covers Core/App/MCP.
  --normalize-mtimes   Derive file/dir mtimes from content hashes so a
                       restored DerivedData stays up to date across checkouts.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

PROJECT = "macos/Engram.xcodeproj"
PBXPROJ = f"{PROJECT}/project.pbxproj"
RESOLVED = f"{PROJECT}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
ENGRAM_SCHEME = f"{PROJECT}/xcshareddata/xcschemes/Engram.xcscheme"
KEEP_PINS = ("grdb.swift", "swift-argument-parser")


def replace_exactly_once(text, pattern, repl, what):
    new_text, count = re.subn(pattern, repl, text, flags=re.M)
    if count != 1:
        sys.exit(f"prepare-xcode-ci: expected 1 match for {what}, got {count}")
    return new_text


def strip_hummingbird():
    with open(PBXPROJ) as f:
        text = f.read()
    # Only the project-level packageReferences entry ends with ",".
    text = replace_exactly_once(
        text,
        r'^\t+[0-9A-F]{24} /\* XCRemoteSwiftPackageReference "hummingbird" \*/,\n',
        "",
        "hummingbird package reference",
    )
    with open(PBXPROJ, "w") as f:
        f.write(text)

    with open(RESOLVED) as f:
        resolved = json.load(f)
    resolved["pins"] = [p for p in resolved["pins"] if p["identity"] in KEEP_PINS]
    if len(resolved["pins"]) != len(KEEP_PINS):
        sys.exit("prepare-xcode-ci: GRDB/ArgumentParser pins missing")
    with open(RESOLVED, "w") as f:
        json.dump(resolved, f, indent=2)


def mcp_in_engram_scheme():
    with open(ENGRAM_SCHEME) as f:
        text = f.read()
    text = replace_exactly_once(
        text, r"3E8B4E524AA151B373A0BC91", "4BEDF7101A8E6E1E3BE7587E", "EngramUITests id"
    )
    text = text.replace("EngramUITests", "EngramMCPTests")
    with open(ENGRAM_SCHEME, "w") as f:
        f.write(text)


def stable_time(digest):
    return 1700000000 + int.from_bytes(digest[:4], "big") % 50000000


def normalize_mtimes():
    dirs = set()
    for raw in subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0"):
        path = raw.decode()
        if not path or os.path.islink(path) or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            ts = stable_time(hashlib.sha256(f.read()).digest())
        os.utime(path, (ts, ts))
        parent = os.path.dirname(path)
        while parent and parent not in dirs:
            dirs.add(parent)
            parent = os.path.dirname(parent)
    for path in sorted(dirs, key=len, reverse=True):
        if os.path.isdir(path) and not os.path.islink(path):
            names = b"\0".join(sorted(n.encode() for n in os.listdir(path)))
            ts = stable_time(hashlib.sha256(names).digest())
            os.utime(path, (ts, ts))


ACTIONS = {
    "--strip-hummingbird": strip_hummingbird,
    "--mcp-in-engram-scheme": mcp_in_engram_scheme,
    "--normalize-mtimes": normalize_mtimes,
}

if __name__ == "__main__":
    unknown = [a for a in sys.argv[1:] if a not in ACTIONS]
    if unknown or len(sys.argv) < 2:
        sys.exit(f"usage: {sys.argv[0]} [{' | '.join(ACTIONS)}]...")
    # Fixed order: project edits first, mtime normalization last.
    for flag, action in ACTIONS.items():
        if flag in sys.argv[1:]:
            action()

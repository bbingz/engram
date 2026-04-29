#!/usr/bin/env python3
"""Generate golden `expected.jsonl` files by applying Python mvp.py's exact
patch semantics to `input.jsonl` fixtures.

**Drift-proof**: imports mvp.py's `patch_file` and `auto_fix_dot_quote` as
live functions via importlib, so if mvp.py's regex ever changes this
generator picks it up automatically. Running with --verify checks that the
on-disk expected.jsonl already matches what mvp.py would produce now; drift
fails the CI.

Usage:
    ./scripts/generate-golden-patch.py [case_dir ...]
    ./scripts/generate-golden-patch.py --all
    ./scripts/generate-golden-patch.py --verify   # CI: fail if drift

Each case dir must contain:
  - input.jsonl        (raw input bytes)
  - meta.json          ({"old": "...", "new": "...", "autoFixDotQuote": bool?})

After running, the dir will contain:
  - expected.jsonl     (bytes after applying mvp.py semantics)
  - expected.sha256    (hex sha256 of expected.jsonl)
"""

import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
FIXTURE_ROOT = REPO_ROOT / "tests" / "fixtures" / "project-move" / "golden"
MVP_PATH = Path(os.environ.get(
    "ENGRAM_MVP_PATH",
    "/Users/example/-Code-/_项目扫描报告/mvp",
))


def _load_mvp():
    """Load mvp.py as a module via importlib — mvp has no .py suffix."""
    if not MVP_PATH.exists():
        raise FileNotFoundError(
            f"mvp not found at {MVP_PATH}. Set ENGRAM_MVP_PATH env var to override."
        )
    spec = importlib.util.spec_from_file_location(
        "engram_mvp_oracle", MVP_PATH,
        # mvp has no .py suffix; tell importlib to treat it as source
        loader=importlib.machinery.SourceFileLoader("engram_mvp_oracle", str(MVP_PATH)),
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not build import spec for {MVP_PATH}")
    module = importlib.util.module_from_spec(spec)
    # Prevent mvp's `if __name__ == '__main__'` block from firing
    spec.loader.exec_module(module)
    return module


def patch_bytes(mvp, data: bytes, old: str, new: str) -> tuple[bytes, int]:
    """Apply mvp.patch_file semantics by actually invoking mvp.patch_file
    on a tempfile. This ensures any change to mvp.py's regex is picked up
    automatically — no drift possible.
    """
    import tempfile
    with tempfile.NamedTemporaryFile(delete=False, suffix=".jsonl") as f:
        f.write(data)
        tmp_path = Path(f.name)
    try:
        count = mvp.patch_file(tmp_path, old, new)
        patched = tmp_path.read_bytes()
    finally:
        tmp_path.unlink(missing_ok=True)
        # mvp.patch_file may leave a .mvp-tmp file behind on error
        Path(str(tmp_path) + ".mvp-tmp").unlink(missing_ok=True)
    return patched, count


def auto_fix_dot_quote_bytes(mvp, data: bytes, old: str, new: str) -> tuple[bytes, int]:
    """Apply mvp.auto_fix_dot_quote by invoking the real function on a tempfile."""
    import tempfile
    with tempfile.NamedTemporaryFile(delete=False, suffix=".jsonl") as f:
        f.write(data)
        tmp_path = Path(f.name)
    try:
        count = mvp.auto_fix_dot_quote([tmp_path], old, new)
        patched = tmp_path.read_bytes()
    finally:
        tmp_path.unlink(missing_ok=True)
        Path(str(tmp_path) + ".mvp-tmp").unlink(missing_ok=True)
    return patched, count


def process_case(mvp, case_dir: Path, verify: bool = False) -> dict:
    input_path = case_dir / "input.jsonl"
    meta_path = case_dir / "meta.json"
    expected_path = case_dir / "expected.jsonl"
    sha_path = case_dir / "expected.sha256"

    if not input_path.exists() or not meta_path.exists():
        raise FileNotFoundError(f"{case_dir}: missing input.jsonl or meta.json")

    meta = json.loads(meta_path.read_text())
    data = input_path.read_bytes()

    patched, count = patch_bytes(mvp, data, meta["old"], meta["new"])
    if meta.get("autoFixDotQuote", False):
        patched, extra = auto_fix_dot_quote_bytes(mvp, patched, meta["old"], meta["new"])
        count += extra

    digest = hashlib.sha256(patched).hexdigest()

    if verify:
        existing_digest = sha_path.read_text().strip() if sha_path.exists() else ""
        if existing_digest != digest:
            raise RuntimeError(
                f"DRIFT in {case_dir.name}: existing sha256={existing_digest}, "
                f"current mvp.py output sha256={digest}. Regenerate goldens."
            )
    else:
        expected_path.write_bytes(patched)
        sha_path.write_text(digest + "\n")

    return {
        "case": case_dir.name,
        "replacements": count,
        "sha256": digest,
        "bytes": len(patched),
        "mvp_path": str(MVP_PATH),
    }


def main() -> int:
    verify = False
    args = sys.argv[1:]
    if args and args[0] == "--verify":
        verify = True
        args = args[1:]

    mvp = _load_mvp()

    if args and args[0] == "--all" or (not args and verify):
        dirs = sorted([d for d in FIXTURE_ROOT.iterdir() if d.is_dir()])
    elif args:
        dirs = [Path(p) for p in args]
    else:
        print(__doc__)
        return 1

    try:
        results = [process_case(mvp, d, verify=verify) for d in dirs]
    except RuntimeError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 2

    print(json.dumps(results, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Keep unchanged checkout mtimes stable for SwiftPM's restored build database.

Only a matching content hash permits restoring a timestamp. Changed/new inputs
retain checkout timestamps and are rebuilt normally. Never skips a build/test.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def inputs():
    names = subprocess.check_output([
        "git", "ls-files", "-z", "Package.swift", "Package.resolved", "Sources",
        "Tests", "Vendor", "Resources",
    ]).decode().split("\0")
    return [Path(name) for name in names if name and Path(name).is_file() and not Path(name).is_symlink()]


def run(mode, manifest):
    if mode == "restore":
        try:
            records = json.loads(manifest.read_text())
        except (OSError, ValueError):
            records = {}
        restored = 0
        for path in inputs():
            record = records.get(str(path))
            if record and hashlib.sha256(path.read_bytes()).hexdigest() == record[0]:
                os.utime(path, ns=(path.stat().st_atime_ns, record[1]))
                restored += 1
        print(f"Restored timestamps for {restored} content-identical inputs")
    elif mode == "save":
        records = {str(p): [hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns] for p in inputs()}
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps(records))
    else:
        raise ValueError("Expected restore or save")


if __name__ == "__main__":
    run(sys.argv[1], Path(sys.argv[2]))

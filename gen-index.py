#!/usr/bin/env python3
"""Generate catalog.json and per-package file hashes."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
KINDS = {"plugin": ROOT / "plugins", "tui": ROOT / "tuis"}

def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true', help='fail if catalog.json is stale')
    args = parser.parse_args()
    entries = []
    packages = [(kind, p) for kind, d in KINDS.items() if d.is_dir() for p in d.iterdir() if p.is_dir()]
    for kind, package in sorted(packages, key=lambda kp: kp[1].name):
        manifest_path = package / "manifest.json"
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        files = []
        for path in sorted(p for p in package.rglob("*") if p.is_file()):
            files.append({"path": path.relative_to(package).as_posix(), "sha256": sha256(path)})
        entry = {
            "name": package.name,
            "title": manifest.get("title", package.name),
            "kind": kind,
            "version": manifest.get("version", "1.0.0"),
            "description": manifest.get("description", ""),
            "min_bone_version": manifest.get("min_bone_version", "0.1.0"),
            "capabilities": manifest.get("capabilities", []),
            "files": files,
        }
        entries.append(entry)
    output = json.dumps(entries, indent=2) + "\n"
    target = ROOT / "catalog.json"
    if args.check:
        if not target.exists() or target.read_text() != output:
            raise SystemExit('catalog.json is stale; run python3 gen-index.py')
    else:
        target.write_text(output)

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Refresh the distributable patch with repository-relative headers only."""
from pathlib import Path
import difflib
import hashlib
import subprocess

root = Path(__file__).resolve().parent
upstream = root / "build/upstream"
upstream.mkdir(exist_ok=True)
original = upstream / "UxPlay-1.73.7"
if not original.exists():
    subprocess.run(["tar", "-xzf", str(root / "downloads/UxPlay-v1.73.7.tar.gz"), "-C", str(upstream)], check=True)
current = root / "sources/UxPlay-1.73.7"
chunks = []
for path in sorted(current.rglob("*")):
    if not path.is_file():
        continue
    relative = path.relative_to(current)
    before_path = original / relative
    before = before_path.read_bytes() if before_path.exists() else b""
    after = path.read_bytes()
    if before != after:
        chunks.extend(difflib.unified_diff(before.decode().splitlines(keepends=True),
                                          after.decode().splitlines(keepends=True),
                                          fromfile="a/" + str(relative), tofile="b/" + str(relative)))
patches = root / "patches"
patches.mkdir(exist_ok=True)
patch = patches / "ipad-window-hardening.patch"
patch.write_text("".join(chunks))
digest = hashlib.sha256(patch.read_bytes()).hexdigest()
(patches / "SHA256SUMS").write_text(digest + "  ipad-window-hardening.patch\n")
print("Patch SHA-256:", digest)

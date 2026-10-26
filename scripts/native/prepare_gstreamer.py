#!/usr/bin/env python3
"""Merge extracted official PKG payloads without executing installer scripts."""
from pathlib import Path
import shutil
import os

def merge(source, destination):
    if source.is_symlink():
        if destination.is_symlink() or destination.exists():
            destination.unlink()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(os.readlink(source))
    elif source.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
        for child in source.iterdir():
            merge(child, destination / child.name)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_symlink():
            destination.unlink()
        shutil.copy2(source, destination)

root = Path(__file__).resolve().parent
stage = root / "build/gstreamer"
stage.mkdir(exist_ok=True)
for payload in sorted((root / "build/gst-runtime-extracted").glob("*.pkg/Payload")):
    for name in ("lib", "libexec"):
        if (payload / name).is_dir():
            merge(payload / name, stage / name)
for payload in sorted((root / "build/gst-devel-extracted").glob("*.pkg/Payload")):
    for name in ("include", "lib/pkgconfig", "lib/glib-2.0/include", "share/licenses"):
        if (payload / name).is_dir():
            merge(payload / name, stage / name)
    if (payload / "bin/pkg-config").exists():
        (stage / "bin").mkdir(exist_ok=True)
        shutil.copy2(payload / "bin/pkg-config", stage / "bin/pkg-config")
for name in ("gst-inspect-1.0", "gst-launch-1.0"):
    source = next((root / "build/gst-runtime-extracted").glob("*/Payload/bin/" + name))
    shutil.copy2(source, stage / "bin" / name)
print(stage)

#!/usr/bin/env python3
"""Collect verified native dependency sources without installing or executing them.

Run from any directory. Downloads stay in downloads/; the separate release
archive is written under build/. No application or running receiver is touched.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--offline", action="store_true", help="verify cached archives only; never download")
args = parser.parse_args()


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


manifest = {name: details for name, details in json.loads((ROOT / "dependencies.json").read_text()).items()
            if not name.endswith(".pkg")}
manifest.update(json.loads((ROOT / "source-dependencies.json").read_text()))
runtime = json.loads((ROOT / "bundle/Wireless/manifest.json").read_text())
components = json.loads((ROOT / "runtime-components.json").read_text())
if set(runtime["files"]) != set(components):
    raise SystemExit("Runtime changed: review runtime-components.json before releasing source")
source_components = {"UxPlay", "MoltenVK", "glib", "proxy-libintl", "libffi", "pcre2", "zlib", "libpng", "orc", "graphene", "libjpeg-turbo", "gstreamer", "gst-plugins-base", "gst-plugins-good", "gst-plugins-bad"}
if set(components.values()) != source_components:
    raise SystemExit("Runtime component source coverage changed")
downloads = ROOT / "downloads"
downloads.mkdir(exist_ok=True)
verified = []
for name, details in manifest.items():
    if Path(name).name != name or not details["url"].startswith("https://"):
        raise SystemExit("Unsafe source manifest entry")
    path = downloads / name
    if path.exists() and digest(path) != details["sha256"]:
        raise SystemExit("Cached source checksum mismatch: " + name)
    if not path.exists():
        if args.offline:
            raise SystemExit("Required source archive missing: " + name)
        temporary = downloads / (name + ".partial")
        urls = [details["url"]]
        if "recipe" in details:
            upstream_name = details["url"].rsplit("/", 1)[-1]
            urls += ["https://gstreamer.freedesktop.org/src/mirror/" + details["recipe"] + "/" + upstream_name]
        for url in urls:
            result = subprocess.run(["curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2",
                                     "--retry", "2", "--connect-timeout", "20", "--max-time", "300",
                                     "--silent", "--show-error", url, "-o", str(temporary)])
            if result.returncode == 0:
                if digest(temporary) != details["sha256"]:
                    temporary.unlink(missing_ok=True)
                    raise SystemExit("Downloaded source checksum mismatch: " + name)
                temporary.replace(path)
                break
            temporary.unlink(missing_ok=True)
        if not path.exists():
            raise SystemExit("Unable to download required source: " + name)
    verified.append((name, details["sha256"]))
    print("Verified " + name, flush=True)

build = ROOT / "build"
build.mkdir(exist_ok=True)
stage = build / "native-corresponding-source"
if stage.exists():
    shutil.rmtree(stage)
(stage / "archives").mkdir(parents=True)
for name, _ in verified:
    shutil.copy2(downloads / name, stage / "archives" / name)
for name in ("NOTICE.txt", "CORRESPONDING-SOURCE.txt", "dependencies.json", "source-dependencies.json", "runtime-components.json",
             "collect_corresponding_source.py", "generate_patch.py", "package_backend.py",
             "prepare_gstreamer.py", "rebuild_backend.py", "smoke_backend.py"):
    shutil.copy2(ROOT / name, stage / name)
for name in ("patches", "tests", "licenses", "sources/UxPlay-1.73.7"):
    shutil.copytree(ROOT / name, stage / name)
(stage / "SHA256SUMS").write_text("".join(checksum + "  archives/" + name + "\n" for name, checksum in verified))
(stage / "SOURCE-RELEASE.json").write_text(json.dumps({
    "product": "iPad to Mac Mirroring native receiver",
    "receiver_sha256": digest(ROOT / "bundle/Wireless/bin/uxplay"),
    "patch_sha256": digest(ROOT / "patches/ipad-window-hardening.patch"),
    "verified_archives": len(verified),
    "mapped_runtime_files": len(components),
    "scope": "Native receiver source, direct static dependency source, selected GStreamer runtime source and upstream recipes/patches. Pair with the matching original app source release.",
    "MoltenVK_source_provenance": "The SDK library embeds MoltenVK1.2.9; the source archive includes that official tag and its pinned dependency revisions. Cerbero records SDK1.3.283.0. The complete upstream SDK has not been rebuilt here."
}, indent=2) + "\n")


def portable_metadata(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = 0
    info.pax_headers = {}
    return info


archive = build / "ipad-to-mac-mirroring-native-corresponding-source.tar.xz"
with tarfile.open(archive, "w:xz", preset=1, format=tarfile.PAX_FORMAT) as output:
    output.add(stage, arcname="native-corresponding-source", filter=portable_metadata)
(build / (archive.name + ".sha256")).write_text(digest(archive) + "  " + archive.name + "\n")
print("Verified source archives: " + str(len(verified)))
print("Release archive: " + str(archive))
print("SHA-256: " + digest(archive))

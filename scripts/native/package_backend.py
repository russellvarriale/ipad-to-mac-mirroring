#!/usr/bin/env python3
"""Bundle only the native receiver's required libraries and GStreamer plugins."""
from pathlib import Path
import os
import shutil
import subprocess
import json

root = Path(__file__).resolve().parent
stage = root / "build/gstreamer"
out = root / "bundle/Wireless"
plugins = ["coreelements", "app", "videoparsersbad", "videoconvertscale",
           "playback", "applemedia", "opengl", "osxvideo", "typefindfunctions"]
pool = {p.name: p.resolve() for p in (stage / "lib").rglob("*") if p.is_file()}
if out.exists():
    shutil.rmtree(out)
(out / "bin").mkdir(parents=True)
(out / "lib/gstreamer-1.0").mkdir(parents=True)

def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

def deps(path):
    return [line.strip().split(" (compatibility")[0]
            for line in run("otool", "-arch", "arm64", "-L", str(path)).splitlines()
            if line.startswith("\t")]

def system(dep):
    return dep.startswith("/usr/lib/") or dep.startswith("/System/Library/")

pending = [(root / "build/uxplay-final/uxplay", out / "bin/uxplay")]
pending += [(pool["libgst" + name + ".dylib"], out / "lib/gstreamer-1.0" / ("libgst" + name + ".dylib")) for name in plugins]
copied = set()
while pending:
    source, destination = pending.pop(0)
    if destination in copied:
        continue
    copied.add(destination)
    arches = run("lipo", "-archs", str(source)).strip().split()
    if len(arches) > 1:
        subprocess.check_call(["lipo", str(source), "-thin", "arm64", "-output", str(destination)])
    else:
        shutil.copy2(source, destination)
    destination.chmod(0o755)
    subprocess.run(["codesign", "--remove-signature", str(destination)], capture_output=True)
    for dep in deps(source):
        if system(dep):
            continue
        name = Path(dep).name
        if name == source.name:
            continue
        if name not in pool:
            raise RuntimeError("Unresolved non-system dependency: " + dep)
        pending.append((pool[name], out / "lib" / name))
        if dep != "@rpath/" + name:
            subprocess.check_call(["install_name_tool", "-change", dep, "@rpath/" + name, str(destination)])

for path in sorted(copied):
    load = run("otool", "-l", str(path)).splitlines()
    rpaths = []
    for i, line in enumerate(load):
        if "cmd LC_RPATH" in line:
            rpaths.append(load[i + 2].strip().split(" (offset")[0][5:])
    for entry in dict.fromkeys(rpaths):
        subprocess.check_call(["install_name_tool", "-delete_rpath", entry, str(path)])
    relative = "@loader_path/../lib" if path.parent.name == "bin" else "@loader_path/.." if path.parent.name == "gstreamer-1.0" else "@loader_path"
    subprocess.check_call(["install_name_tool", "-add_rpath", relative, str(path)])
    if path.parent.name != "bin":
        subprocess.check_call(["install_name_tool", "-id", "@rpath/" + path.name, str(path)])
    subprocess.check_call(["strip", "-S", str(path)])
    subprocess.check_call(["codesign", "--force", "--sign", "-", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

licenses = out / "licenses"
licenses.mkdir()
for name in ("gstreamer-1.0", "gst-plugins-base-1.0", "gst-plugins-good-1.0", "gst-plugins-bad-1.0", "glib", "proxy-libintl", "libffi", "pcre2", "zlib", "libpng", "orc", "graphene", "libjpeg-turbo", "moltenvk"):
    source = stage / "share/licenses" / name
    if source.exists():
        shutil.copytree(source, licenses / name)
shutil.copytree(root / "licenses", licenses, dirs_exist_ok=True)
shutil.copy2(root / "sources/UxPlay-1.73.7/LICENSE", licenses / "UxPlay-GPL-3.0.txt")
shutil.copy2(root / "sources/UxPlay-1.73.7/lib/llhttp/LICENSE-MIT", licenses / "llhttp-MIT.txt")
shutil.copy2(root / "sources/UxPlay-1.73.7/lib/playfair/LICENSE.md", licenses / "PlayFair-GPL-3.0.md")
shutil.copy2(root / "sources/libplist-2.7.0/COPYING.LESSER", licenses / "libplist-LGPL-2.1.txt")
shutil.copy2(root / "sources/libplist-2.7.0/COPYING", licenses / "libplist-GPL-2.0.txt")
openssl_license = root / "sources/openssl-3.6.5/LICENSE.txt"
shutil.copy2(openssl_license, licenses / "OpenSSL-Apache-2.0.txt")
for name in ("NOTICE.txt", "dependencies.json", "source-dependencies.json", "runtime-components.json", "CORRESPONDING-SOURCE.txt"):
    if (root / name).exists():
        shutil.copy2(root / name, out / name)
(out / "manifest.json").write_text(json.dumps({"UxPlay": "1.73.7 + iPad to Mac Mirroring hardening", "GStreamer": "1.28.8", "libplist": "2.7.0", "OpenSSL": "3.6.5", "architecture": "arm64", "plugins": plugins, "files": sorted(str(p.relative_to(out)) for p in copied)}, indent=2) + "\n")
print(str(out))
print(str(sum(p.stat().st_size for p in out.rglob("*") if p.is_file()) // (1024 * 1024)) + " MiB")

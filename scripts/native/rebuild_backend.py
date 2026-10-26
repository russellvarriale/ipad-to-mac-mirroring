#!/usr/bin/env python3
"""Rebuild the arm64 backend using pinned downloads and workspace-only staging.

Requires macOS 14+, Xcode command-line tools, Python 3.9+, CMake, make, Perl,
curl, pkgutil, patch, lipo, install_name_tool, strip, and codesign. No Homebrew
dependency installation, root access, installer execution, or /Library writes.
Allow roughly 8 GiB working space. Output: bundle/Wireless.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
os.chdir(ROOT)
for directory in ("downloads", "sources", "build", "prefix", "patches"):
    (ROOT / directory).mkdir(exist_ok=True)

def run(args, cwd=ROOT, env=None, log=None):
    print("Running", args[0], flush=True)
    if log:
        with (ROOT / "build" / log).open("w") as output:
            subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                           stdout=output, stderr=subprocess.STDOUT, check=True)
    else:
        subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)

for tool in ("curl", "tar", "pkgutil", "patch", "cmake", "make", "perl", "clang", "lipo", "install_name_tool", "strip", "codesign"):
    if not shutil.which(tool):
        raise SystemExit("Required build tool missing: " + tool)
if run_arch := subprocess.check_output(["uname", "-m"], text=True).strip():
    if run_arch != "arm64":
        raise SystemExit("This build script targets an Apple Silicon Mac.")

manifest = json.loads((ROOT / "dependencies.json").read_text())
for filename, details in manifest.items():
    path = ROOT / "downloads" / filename
    if not path.exists():
        run(["curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2", details["url"], "-o", path])
    with path.open("rb") as source:
        checksum = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(block)
    if checksum.hexdigest() != details["sha256"]:
        raise SystemExit("Checksum mismatch; refusing to use " + filename)

for archive, folder, flag in (("UxPlay-v1.73.7.tar.gz", "UxPlay-1.73.7", "-xzf"),
                               ("libplist-2.7.0.tar.bz2", "libplist-2.7.0", "-xjf"),
                               ("openssl-3.6.5.tar.gz", "openssl-3.6.5", "-xzf")):
    if not (ROOT / "sources" / folder).exists():
        run(["tar", flag, ROOT / "downloads" / archive, "-C", ROOT / "sources"])
        if folder.startswith("UxPlay"):
            run(["patch", "-p1", "-i", ROOT / "patches/ipad-window-hardening.patch"], ROOT / "sources" / folder)

for kind, filename in (("runtime", "gstreamer-1.0-1.28.8-universal.pkg"),
                        ("devel", "gstreamer-1.0-devel-1.28.8-universal.pkg")):
    extracted = ROOT / "build" / ("gst-" + kind + "-extracted")
    if not extracted.exists():
        run(["pkgutil", "--expand-full", ROOT / "downloads" / filename, extracted])
run([sys.executable, ROOT / "prepare_gstreamer.py"])

maps = ["-ffile-prefix-map=" + str(ROOT) + "=vendor", "-fdebug-prefix-map=" + str(ROOT) + "=vendor"]
common_flags = " ".join(["-O2", "-mmacosx-version-min=14.0"] + maps)
plist_build = ROOT / "build/libplist"
plist_build.mkdir(exist_ok=True)
run([ROOT / "sources/libplist-2.7.0/configure", "--prefix=" + str(ROOT / "prefix"),
     "--disable-shared", "--enable-static", "--without-cython", "--without-tools", "--without-tests",
     "CFLAGS=" + common_flags, "CXXFLAGS=" + common_flags], plist_build, log="libplist-configure.log")
run(["make", "-j4"], plist_build, log="libplist-make.log")
run(["make", "install"], plist_build, log="libplist-install.log")

openssl_build = ROOT / "build/openssl"
openssl_build.mkdir(exist_ok=True)
run([ROOT / "sources/openssl-3.6.5/Configure", "darwin64-arm64-cc", "no-shared", "no-tests", "no-module", "no-ssl3",
     "--prefix=/usr/local/ipad-window-openssl", "--openssldir=/usr/local/ipad-window-openssl/ssl", "--libdir=lib",
     "-mmacosx-version-min=14.0"] + maps, openssl_build, log="openssl-configure.log")
run(["make", "-j4", "build_libs"], openssl_build, log="openssl-make.log")
run(["make", "install_dev", "DESTDIR=" + str(ROOT / "build/openssl-install")], openssl_build, log="openssl-install.log")
openssl_stage = ROOT / "build/openssl-install/usr/local/ipad-window-openssl"
openssl_prefix = ROOT / "prefix/openssl"
shutil.copytree(openssl_stage, openssl_prefix, dirs_exist_ok=True)
for pc in (openssl_prefix / "lib/pkgconfig").glob("*.pc"):
    pc.write_text(pc.read_text().replace("prefix=/usr/local/ipad-window-openssl", "prefix=" + str(openssl_prefix)))

gst = ROOT / "build/gstreamer"
environment = dict(os.environ)
environment["PKG_CONFIG_PATH"] = ":".join(str(p) for p in (ROOT / "prefix/lib/pkgconfig", openssl_prefix / "lib/pkgconfig", gst / "lib/pkgconfig"))
run(["cmake", "-S", ROOT / "sources/UxPlay-1.73.7", "-B", ROOT / "build/uxplay-final",
     "-DPKG_CONFIG_EXECUTABLE=" + str(gst / "bin/pkg-config"),
     "-DCMAKE_PREFIX_PATH=" + ";".join(str(p) for p in (ROOT / "prefix", openssl_prefix, gst)),
     "-DLIBCRYPTO=" + str(openssl_prefix / "lib/libcrypto.a"), "-DCMAKE_BUILD_TYPE=Release",
     "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
     "-DCMAKE_C_FLAGS=" + " ".join(maps), "-DCMAKE_CXX_FLAGS=" + " ".join(maps), "-DNO_MARCH_NATIVE=ON"],
    env=environment, log="uxplay-configure.log")
run(["cmake", "--build", ROOT / "build/uxplay-final", "-j4"], log="uxplay-make.log")
run([sys.executable, ROOT / "package_backend.py"])
run([ROOT / "bundle/Wireless/bin/uxplay", "-v"])
print("Receiver bundle:", ROOT / "bundle/Wireless")

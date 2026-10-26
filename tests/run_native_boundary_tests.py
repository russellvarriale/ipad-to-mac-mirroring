#!/usr/bin/env python3
"""Compile focused native boundary checks against the specified current source.

Example, from the prepared source folder:
  python3 tests/run_native_boundary_tests.py --source scripts/native/sources/UxPlay-1.73.7

Requirements: macOS Xcode Command Line Tools and Python 3. Uses only the Python
standard library. Compiled test executables live in a temporary directory which
is removed on exit. No receiver, network service, iPad capture, or UI is started.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True,
                        help="Current patched UxPlay source directory; relative paths use the current working directory")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    lib = source / "lib"
    tests = Path(__file__).resolve().parent
    for required in (lib / "http_request.c", lib / "raop_rtp_mirror.c",
                     lib / "byteutils.c", lib / "llhttp/llhttp.c"):
        if not required.is_file():
            parser.error(f"Missing required source file: {required.name}")

    # Pull the helper definitions from the source being compiled, never from a
    # stored implementation copy. Fail if a source edit changes these anchors.
    mirror = (lib / "raop_rtp_mirror.c").read_text()
    start_anchor = "static bool\nsame_mirror_peer"
    end_anchor = "/* for MacOS,"
    if mirror.count(start_anchor) != 1:
        raise SystemExit("Current mirror peer helper not found uniquely; update the test extraction anchors.")
    start = mirror.index(start_anchor)
    end = mirror.find(end_anchor, start)
    if end == -1 or "valid_codec_payload" not in mirror[start:end]:
        raise SystemExit("Current codec helper extraction boundary not found; update the test extraction anchors.")
    template = (tests / "mirror-boundary-tests.c.in").read_text()
    marker = "/* INSERT_CURRENT_MIRROR_HELPERS_HERE */"
    if template.count(marker) != 1:
        raise SystemExit("Invalid mirror boundary test template.")
    rendered = template.replace(marker, mirror[start:end])
    compiler = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    flags = [compiler, "-std=c11", "-g", "-fsanitize=address,undefined",
             "-fno-omit-frame-pointer", "-I" + str(lib), "-I" + str(lib / "llhttp")]
    environment = os.environ.copy()
    environment["UBSAN_OPTIONS"] = "halt_on_error=1"
    environment["ASAN_OPTIONS"] = "halt_on_error=1"

    with tempfile.TemporaryDirectory(prefix="ipad-window-boundary-tests-") as temporary:
        scratch = Path(temporary)
        mirror_test = scratch / "mirror-boundary-tests.c"
        mirror_test.write_text(rendered)
        http_binary = scratch / "http-boundary-tests"
        mirror_binary = scratch / "mirror-boundary-tests"
        subprocess.run(flags + [str(tests / "http-boundary-tests.c"),
                       str(lib / "http_request.c"), str(lib / "llhttp/api.c"),
                       str(lib / "llhttp/http.c"), str(lib / "llhttp/llhttp.c"),
                       "-o", str(http_binary)], check=True)
        subprocess.run([str(http_binary)], env=environment, check=True)
        subprocess.run(flags + [str(mirror_test), str(lib / "byteutils.c"),
                       "-o", str(mirror_binary)], check=True)
        subprocess.run([str(mirror_binary)], env=environment, check=True)
    print("PASS: 401 focused native boundary cases; ASan and UBSan enabled")


if __name__ == "__main__":
    main()

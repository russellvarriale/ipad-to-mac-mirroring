#!/usr/bin/env python3
"""Test actual production H.264 parsing/rendering using synthetic VideoToolbox frames.

Requires Apple silicon macOS 14.4+, Xcode command line tools, and a logged-in
graphical session with access to the system video codec service. Briefly opens a
small synthetic-only window. Does not capture a device/screen or use networking.
"""
import argparse
import pathlib
import platform
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path,
                        help="Production WirelessVideo.swift path (sibling transport source is required)")
    args = parser.parse_args()
    here = pathlib.Path(__file__).resolve().parent
    default_source = here.parent / "WirelessVideo.swift"
    if not default_source.is_file():
        default_source = here.parent / "ipad-window" / "WirelessVideo.swift"
    source = (args.source or default_source).resolve()
    transport = source.with_name("WirelessVideoTransport.swift")
    tests = here / "WirelessVideoRendererTests.swift"
    version = tuple(int(part) for part in (platform.mac_ver()[0] or "0").split(".")[:2])
    if platform.system() != "Darwin" or platform.machine() != "arm64" or version < (14, 4):
        raise SystemExit("These synthetic renderer tests require Apple silicon macOS 14.4 or later.")
    if not all(path.is_file() for path in (source, transport, tests)):
        raise SystemExit("Production renderer, sibling transport, or test source was not found.")
    with tempfile.TemporaryDirectory(prefix="ipad-window-renderer-tests-") as scratch:
        scratch = pathlib.Path(scratch)
        executable = scratch / "renderer-tests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos14.4",
                        "-module-cache-path", str(scratch / "module-cache"),
                        str(source), str(transport), str(tests), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError:
        raise SystemExit("FAIL: synthetic renderer build/test did not complete.")

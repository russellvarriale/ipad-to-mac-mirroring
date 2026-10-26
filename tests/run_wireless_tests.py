#!/usr/bin/env python3
"""Compile actual private Swift helpers together with same-file test extensions.

No production file is modified. A local C pipe fixture is compiled and launched;
it contains no receiver/network/window code. No receiver or window starts.
Only case counts and pass/fail names are printed; codes/tokens are never printed.
Requires macOS and Xcode command line tools.
"""
import argparse
import pathlib
import subprocess
import tempfile


def main():
    here = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    candidates = (here.parent / "WirelessReceiver.swift", here.parent / "ipad-window" / "WirelessReceiver.swift")
    default_source = next((path for path in candidates if path.is_file()), candidates[0])
    parser.add_argument("--source", type=pathlib.Path,
                        default=default_source)
    args = parser.parse_args()
    production = args.source.read_text(encoding="utf-8")
    transport_source = args.source.parent / "WirelessVideoTransport.swift"
    if not transport_source.is_file():
        raise SystemExit("Production controller's sibling WirelessVideoTransport.swift was not found.")
    production += "\n\n" + transport_source.read_text(encoding="utf-8")
    tests = (here / "WirelessReceiverTests.swift").read_text(encoding="utf-8")
    ipc_tests = (here / "WirelessIPCTests.swift").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="ipad-window-wireless-tests-") as scratch:
        scratch = pathlib.Path(scratch)
        combined = scratch / "WirelessReceiverTestsCombined.swift"
        executable = scratch / "wireless-tests"
        combined.write_text(production + "\n\n" + tests + "\n\n" + ipc_tests, encoding="utf-8")
        resources = scratch / "Resources"
        fixture = resources / "Wireless" / "bin" / "uxplay"
        fixture.parent.mkdir(parents=True)
        (resources / "Wireless" / "lib" / "gstreamer-1.0").mkdir(parents=True)
        fixture_compile = subprocess.run([
            "xcrun", "clang", "-target", "arm64-apple-macos14.0",
            str(here / "WirelessIPCFixture.c"), "-o", str(fixture)
        ], capture_output=True, text=True)
        if fixture_compile.returncode:
            print("FAIL: local IPC fixture did not compile")
            return 1
        compile_result = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos14.0",
            "-module-cache-path", str(scratch / "module-cache"),
            str(combined), "-o", str(executable)
        ], capture_output=True, text=True)
        if compile_result.returncode:
            # Keep absolute paths out of the reusable report, retaining compiler
            # diagnostics sufficient to locate an error in the combined source.
            print("FAIL: wireless test harness did not compile")
            for line in compile_result.stderr.splitlines():
                print(line.replace(str(scratch), "<temporary-test-directory>"))
            return 1
        return subprocess.run([str(executable), str(resources)]).returncode


if __name__ == "__main__":
    raise SystemExit(main())

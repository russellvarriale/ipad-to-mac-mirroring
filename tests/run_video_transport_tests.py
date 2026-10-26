#!/usr/bin/env python3
"""Compile the current Swift transport with bounded parser and local IPC tests."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
project = Path(__file__).resolve().parents[1]
source_candidates = (project / "WirelessVideoTransport.swift", project / "ipad-window" / "WirelessVideoTransport.swift")
default_source = next((path for path in source_candidates if path.is_file()), source_candidates[0])
parser.add_argument("--source", type=Path, default=default_source)
args = parser.parse_args()
test_source = Path(__file__).with_name("WirelessVideoTransportTests.swift")
fixture = r'''
#include <sys/socket.h>
#include <unistd.h>
#include <stdint.h>
int main(void) {
    int type = 0;
    socklen_t size = sizeof(type);
    if (getsockopt(0, SOL_SOCKET, SO_TYPE, &type, &size) || type != SOCK_STREAM) return 2;
    const uint8_t bytes[] = {
        'I','W','V','1',0,0,0,2,0,0,0,0,0,0,0,0,
        'I','W','V','1',0,0,0,1,0,0,0,8,0,0,0,0,
        0,0,0,1,0x65,1,2,3
    };
    for (size_t i = 0; i < sizeof(bytes); ++i) {
        if (write(0, bytes+i, 1) != 1) return 3;
        usleep(200);
    }
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="ipad-window-video-tests-", dir="/private/tmp") as scratch:
    scratch = Path(scratch)
    (scratch / "Fixture.c").write_text(fixture)
    subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", str(scratch / "Fixture.c"), "-o", str(scratch / "fixture")], check=True)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(scratch / "module-cache"), str(args.source), str(test_source), "-o", str(scratch / "video-tests")], check=True)
    subprocess.run([str(scratch / "video-tests"), str(scratch / "fixture")], check=True, timeout=30)

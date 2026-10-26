#!/usr/bin/env python3
"""Local backend checks; --listen briefly advertises a PIN-protected test receiver."""
from pathlib import Path
import json
import os
import plistlib
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent
BUNDLE = ROOT / "bundle/Wireless"
BINARY = BUNDLE / "bin/uxplay"

if len(sys.argv) > 1 and sys.argv[1] == "--parent":
    scratch = Path(sys.argv[2])
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                   "TMPDIR": str(scratch), "XDG_CACHE_HOME": str(scratch / "cache"),
                   "XDG_CONFIG_HOME": str(scratch / "config"), "GSETTINGS_BACKEND": "memory",
                   "GST_PLUGIN_SYSTEM_PATH_1_0": str(BUNDLE / "lib/gstreamer-1.0"),
                   "GST_PLUGIN_PATH_1_0": "", "GST_REGISTRY": str(scratch / "registry.bin"),
                   "GST_REGISTRY_FORK": "no", "GST_DEBUG": "0", "UXPLAYRC": "/dev/null",
                   "IPAD_WINDOW_EVENT_TOKEN": str(uuid.uuid4())}
    video_peer = video_child = None
    embedded = "--embedded" in sys.argv
    if embedded:
        environment["IPAD_WINDOW_EMBEDDED_VIDEO"] = "1"
        video_peer, video_child = socket.socketpair()
    with (scratch / "receiver.log").open("wb") as output:
        child = subprocess.Popen([str(BINARY), "-n", "iPad to Mac Mirroring Backend Test", "-nh", "-pw", "-m",
                                  "-as", "0", "-vsync", "no", "-vs", "glimagesink", "-nofreeze", "-nc", "no",
                                  "-rc", "/dev/null"], cwd=scratch, env=environment,
                                 stdin=video_child if embedded else subprocess.DEVNULL, stdout=output, stderr=output)
        if video_child: video_child.close()
        (scratch / "pid").write_text(str(child.pid))
        if video_peer:
            video_peer.settimeout(5)
            packet = bytearray()
            while len(packet) < 16:
                chunk = video_peer.recv(16 - len(packet))
                if not chunk: raise RuntimeError("Embedded receiver closed before startup reset")
                packet.extend(chunk)
            (scratch / "initial-video-packet").write_bytes(packet)
        until = time.monotonic() + 60
        while time.monotonic() < until:
            if video_peer and (scratch / "close-video").exists():
                video_peer.close()
                video_peer = None
            time.sleep(.1)
    sys.exit(0)

result = {}
for arguments in (["-v"], ["-hls"], ["-mp4", "should-not-exist.mp4"], ["-rc", "/tmp/disallowed-rc"]):
    completed = subprocess.run([str(BINARY)] + arguments, capture_output=True, timeout=5)
    expected = 0 if arguments == ["-v"] else 1
    assert completed.returncode == expected, (arguments, completed.returncode)
result["version_and_unsafe_option_rejection"] = "pass"

for path in BUNDLE.rglob("*"):
    if not path.is_file() or (path.suffix != ".dylib" and path.name != "uxplay"):
        continue
    text = subprocess.check_output(["otool", "-L", str(path)], text=True)
    for line in text.splitlines()[1:]:
        dep = line.strip().split(" (")[0]
        assert dep.startswith(("@rpath/", "/usr/lib/", "/System/Library/")), dep
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True, capture_output=True)
    data = subprocess.check_output(["strings", str(path)])
    assert str(ROOT).encode() not in data
    assert Path.home().name.encode() not in data
result["relative_linkage_signatures_and_private_path_scan"] = "pass"

if "--embedded" in sys.argv:
    for mode in ("1", "0", ""):
        environment = dict(os.environ, IPAD_WINDOW_EMBEDDED_VIDEO=mode)
        completed = subprocess.run([str(BINARY), "-n", "iPad to Mac Mirroring Invalid Transport Test", "-nh", "-pw", "-m", "-as", "0"],
                                   env=environment, stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
        assert completed.returncode == 1
    result["invalid_embedded_descriptor_and_mode_rejected"] = "pass"

if "--listen" in sys.argv or "--embedded" in sys.argv:
    with tempfile.TemporaryDirectory(prefix="ipad-window-backend-test-", dir=ROOT / "build") as temp:
        scratch = Path(temp)
        parent_arguments = [sys.executable, str(Path(__file__).resolve()), "--parent", temp]
        if "--embedded" in sys.argv: parent_arguments.append("--embedded")
        parent = subprocess.Popen(parent_arguments)
        receiver_pid = None
        try:
            deadline = time.monotonic() + 15
            listening = []
            while time.monotonic() < deadline:
                if (scratch / "pid").exists():
                    receiver_pid = int((scratch / "pid").read_text())
                    listing = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(receiver_pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], capture_output=True, text=True)
                    listening = [int(line.rsplit(":", 1)[1]) for line in listing.stdout.splitlines() if line.startswith("n")]
                    if listening:
                        break
                time.sleep(.2)
            if not listening:
                failure = (scratch / "receiver.log").read_text(errors="replace")
                (ROOT / "build/smoke-last-failure.log").write_text(failure)
                raise AssertionError("Receiver did not begin listening; see private build/smoke-last-failure.log")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                lines = (scratch / "receiver.log").read_text(errors="replace").splitlines()
                events = [line.split() for line in lines if line.startswith("IPADWINDOW_EVENT ")]
                if any(len(parts) >= 3 and parts[2] == "BONJOUR_FAILED" for parts in events):
                    raise AssertionError("Bonjour registration failed")
                if any(len(parts) == 3 and parts[2] == "BONJOUR_READY" for parts in events):
                    break
                time.sleep(.1)
            else:
                raise AssertionError("Bonjour registration never completed")
            result["both_bonjour_registrations_acknowledged"] = "pass"
            if "--embedded" in sys.argv:
                deadline = time.monotonic() + 3
                while not (scratch / "initial-video-packet").exists() and time.monotonic() < deadline: time.sleep(.05)
                assert (scratch / "initial-video-packet").read_bytes() == b"IWV1\x00\x00\x00\x02" + bytes(8)
                result["embedded_startup_reset_framing"] = "pass"
                script = 'ObjC.import("AppKit"); ObjC.import("CoreGraphics"); function run(argv) { var pid=Number(argv[0]); var windows=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(0,0))).filter(function(w){return w.kCGWindowOwnerPID===pid;}); return String(windows.length); }'
                count = subprocess.check_output(["/usr/bin/osascript", "-l", "JavaScript", "-e", script, str(receiver_pid)], text=True).strip()
                assert count == "0", "Embedded receiver created a helper window"
                result["embedded_receiver_has_no_window"] = "pass"
            with socket.create_connection(("127.0.0.1", listening[0]), timeout=3) as peer:
                peer.sendall(b"POST /play HTTP/1.1\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n")
                reply = peer.recv(4096)
                assert b"403 Mirroring Only" in reply, reply[:100]
            result["remote_url_playback_rejected_before_dispatch"] = "pass"
            # These unused legacy routes must be denied before parsing SRP stages.
            early_srp = [b"", plistlib.dumps({"epk": bytes(32), "authTag": bytes(16)}, fmt=plistlib.FMT_BINARY),
                         plistlib.dumps({"pk": bytes(256), "proof": bytes(64)}, fmt=plistlib.FMT_BINARY)]
            for route in (b"/pair-pin-start", b"/pair-setup-pin"):
                for payload in early_srp:
                    with socket.create_connection(("127.0.0.1", listening[0]), timeout=3) as peer:
                        peer.sendall(b"POST " + route + b" RTSP/1.0\r\nCSeq: 1\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: " +
                                     str(len(payload)).encode() + b"\r\n\r\n" + payload)
                        assert b"403 Legacy Pairing Disabled" in peer.recv(4096)
            result["unused_srp_routes_rejected_before_dispatch"] = "pass"
            # Keep the intended password-mode SETUP admission challenge intact.
            setup = plistlib.dumps({"eiv": bytes(16), "ekey": bytes(72), "deviceID": "02:00:00:00:00:01"}, fmt=plistlib.FMT_BINARY)
            with socket.create_connection(("127.0.0.1", listening[0]), timeout=3) as peer:
                peer.sendall(b"SETUP rtsp://localhost/test RTSP/1.0\r\nCSeq: 1\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: " +
                             str(len(setup)).encode() + b"\r\n\r\n" + setup)
                challenge = peer.recv(4096)
                assert b"401" in challenge and b"WWW-Authenticate: Digest" in challenge
            result["password_digest_challenge_preserved"] = "pass"
            # Malformed low-order X25519 keys reject this connection, not the helper.
            for low_order in (bytes(32), b"\x01" + bytes(31)):
                with socket.create_connection(("127.0.0.1", listening[0]), timeout=3) as peer:
                    peer.sendall(b"POST /pair-setup RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 32\r\n\r\n" + bytes(32))
                    assert b"200 OK" in peer.recv(4096)
                    verify = b"\x01\x00\x00\x00" + low_order + bytes(32)
                    peer.sendall(b"POST /pair-verify RTSP/1.0\r\nCSeq: 2\r\nContent-Length: " +
                                 str(len(verify)).encode() + b"\r\n\r\n" + verify)
                    rejection = peer.recv(4096)
                    assert any(code in rejection.split(b"\r\n",1)[0] for code in (b"400", b"401", b"470")), rejection[:100]
            result["low_order_x25519_rejected_without_process_exit"] = "pass"
            with socket.create_connection(("127.0.0.1", listening[0]), timeout=3) as peer:
                peer.sendall(b"POST /pair-setup RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 32\r\n\r\n" + bytes(32))
                assert b"200 OK" in peer.recv(4096)
                verify = b"\x01\x00\x00\x00\x09" + bytes(31) + bytes(32)
                peer.sendall(b"POST /pair-verify RTSP/1.0\r\nCSeq: 2\r\nContent-Length: " +
                             str(len(verify)).encode() + b"\r\n\r\n" + verify)
                response = peer.recv(4096)
                assert b"200 OK" in response and b"Content-Length: 96" in response
            result["valid_x25519_first_handshake_preserved"] = "pass"
            parent.terminate()
            parent.wait(timeout=3)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                state = subprocess.run(["ps", "-p", str(receiver_pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
                if not state or state.startswith("Z"):
                    break
                time.sleep(.1)
            else:
                raise AssertionError("Receiver survived parent exit")
            result["parent_death_watchdog"] = "pass"
        finally:
            if parent.poll() is None:
                parent.terminate()
                parent.wait(timeout=3)
            if receiver_pid:
                try:
                    os.kill(receiver_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass

if "--embedded" in sys.argv:
    with tempfile.TemporaryDirectory(prefix="ipad-window-peer-close-test-", dir=ROOT / "build") as temp:
        scratch = Path(temp)
        parent = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--parent", temp, "--embedded"])
        receiver_pid = None
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if (scratch / "pid").exists(): receiver_pid = int((scratch / "pid").read_text())
                if (scratch / "initial-video-packet").exists(): break
                time.sleep(.05)
            assert receiver_pid and (scratch / "initial-video-packet").exists()
            (scratch / "close-video").touch()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                state = subprocess.run(["ps", "-p", str(receiver_pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
                if not state or state.startswith("Z"): break
                time.sleep(.05)
            else: raise AssertionError("Idle receiver survived private transport closure")
            assert parent.poll() is None
            result["embedded_idle_peer_close_watchdog"] = "pass"
        finally:
            if parent.poll() is None:
                parent.terminate(); parent.wait(timeout=3)
            if receiver_pid:
                try: os.kill(receiver_pid, signal.SIGTERM)
                except ProcessLookupError: pass

(ROOT / "build/smoke-results.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))

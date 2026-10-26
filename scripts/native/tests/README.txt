iPad to Mac Mirroring native regression checks
===================================

Run these commands from scripts/native in the prepared source folder. Paths
below are relative to that directory; no global dependency installation is
required.

Prerequisites
-------------
Use an Apple Silicon Mac with Xcode Command Line Tools and Python 3. To build
the pinned native dependencies and backend, also install the tools listed by
rebuild_backend.py (including CMake). Run:

    python3 rebuild_backend.py

The rebuild downloads the pinned sources/packages and builds in this directory.
It needs network access and approximately 8 GiB of working space. It creates:

    sources/UxPlay-1.73.7/              patched source
    prefix/openssl/include/           OpenSSL headers
    prefix/openssl/lib/libcrypto.a    local static OpenSSL library
    build/uxplay-final/lib/libairplay.a
    bundle/Wireless/bin/uxplay        packaged receiver
    bundle/Wireless/lib/              packaged runtime dependencies/plugins

No-network sanitizer checks
---------------------------
These tests do not start a receiver, advertise Bonjour services, connect to an
iPad, capture a screen, or change network settings. The commands below compile
and run the exact source used by this project with AddressSanitizer and
UndefinedBehaviorSanitizer enabled.

Five Bonjour lifecycle scenarios:

    mkdir -p build
    clang -fsanitize=address,undefined -fno-omit-frame-pointer -g -I sources/UxPlay-1.73.7/lib tests/bonjour_registration.c -o build/test-bonjour
    ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 ./build/test-bonjour

Expected final line:
    Bonjour lifecycle: 5 scenarios passed (ASan + UBSan)

This test substitutes mock DNS-SD registration functions. It checks both-service
readiness, immediate/asynchronous errors, scheduling failure, duplicate success,
and serial-queue cleanup without using the network.

Twenty-four pairing sequence cases:

    clang -fsanitize=address,undefined -fno-omit-frame-pointer -g -I sources/UxPlay-1.73.7/lib -I prefix/openssl/include tests/pairing_sequence.c build/uxplay-final/lib/libairplay.a prefix/openssl/lib/libcrypto.a -o build/test-pairing-sequence
    ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 ./build/test-pairing-sequence

Expected final line:
    Pairing early sequence: 24 cases passed (ASan + UBSan)

This test includes the current pairing.c directly and links the locally built
supporting archives. It checks missing/out-of-order SRP state, argument bounds,
a valid X25519 handshake, invalid-key rejection, and stale-key cleanup. The test
translation unit is instrumented; the supporting release archives are not.

Fourteen private video transport scenarios:

    clang++ -std=c++11 -fsanitize=address,undefined -fno-omit-frame-pointer -g -I sources/UxPlay-1.73.7 tests/embedded_video_transport.cpp sources/UxPlay-1.73.7/embedded_video.cpp -o build/test-embedded-video
    ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 ./build/test-embedded-video

Expected final line:
    PASS: 14 native embedded-video transport scenarios (ASan + UBSan)

This test uses only local unnamed socketpairs and child processes. It checks
reset/access-unit framing, concurrent packet serialization, payload validation,
the 16 MiB boundary, fragmented reads, bounded backpressure, closed-peer and
unexpected-input handling, invalid descriptors, and creator/parent PID checks.
It starts no receiver, window, Bonjour service, or network listener.

Embedded video transport contract
---------------------------------
The app sets IPAD_WINDOW_EMBEDDED_VIDEO=1 and supplies the child endpoint of a
private AF_UNIX/SOCK_STREAM socketpair as the receiver's standard input (fd 0).
The endpoint must be created by the direct parent running as the same user.
An invalid descriptor or any other value of this environment variable causes
startup to fail before listeners open. Leaving the variable absent preserves
the standalone renderer used by the original smoke test below.

Embedded mode initializes no GStreamer video pipeline or Cocoa video window.
It forwards H264 Annex-B access units to the parent without re-encoding. Status
and PIN events remain on stdout; binary video is written only to the socket.
Each packet has a 16-byte header: ASCII IWV1, big-endian uint32 kind, big-endian
uint32 payload length, and a zero uint32 reserved field. Kind 1 has a nonempty
H264 payload of at most 16 MiB; kind 2 is a reset with zero payload length.
Writes are serialized and must complete within two seconds for each complete
packet. Invalid input, a closed peer, unexpected parent bytes, or persistent
backpressure terminates the receiver. The parent-death watchdog also checks
socket liveness while no frames are being sent.

Temporary receiver smoke test
-----------------------------
The smoke script resolves bundle/Wireless relative to its own location. Keep
that complete runtime bundle in place; passing an application bundle path is
not supported. Run:

    python3 smoke_backend.py --listen

This runs nine checks: version/unsafe-option rejection; relative linkage,
signatures and private-path scanning; both Bonjour registration acknowledgments;
remote-URL playback denial; unused SRP route denial; the required Digest
challenge; low-order X25519 rejection without process exit; a valid X25519 first
handshake; and receiver exit when its parent ends.

Unlike the sanitizer checks, --listen briefly starts and advertises a separate
PIN-protected receiver named "iPad to Mac Mirroring Backend Test" on the local network.
Regression requests go to that test receiver over 127.0.0.1. The script cleans up
its own receiver and temporary files. It does not stop an existing app receiver,
record screen content, or change firewall/network settings. No iPad is needed.

Every result in the printed JSON must be "pass". Running without --listen:

    python3 smoke_backend.py

performs only the version/option and packaged-binary checks and starts no
receiver. The separate 401-case HTTP/codec/peer sanitizer suite is documented
in the source folder's top-level tests directory.

For the production embedded mode, run:

    python3 smoke_backend.py --embedded

This performs all nine original checks plus four embedded-mode checks: invalid
mode/descriptor rejection, initial reset framing, no receiver-owned windows,
and idle peer-close termination. The thirteen printed JSON results must all be
"pass". It briefly advertises its own temporary test receiver, just as --listen
does. It does not connect to or stop the app's current receiver. No iPad or
screen-recording permission is required.

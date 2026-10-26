Current-source test suites

From the project directory:
    python3 tests/run_wireless_tests.py
    python3 tests/run_video_transport_tests.py
    python3 tests/run_video_renderer_tests.py

The runners compile the actual production sources into temporary test harnesses
and remove their executables and compiler caches afterward. No production file
is changed. All require macOS on Apple silicon and Xcode command line tools.
Each accepts --source for a production source in a different location. The
controller and renderer runners require sibling WirelessVideoTransport.swift.
Reports print only case counts and pass/fail names, never session codes/tokens.

Controller/security/status IPC: 110 checks

The runner appends same-file test extensions to an otherwise unmodified copy of
WirelessReceiver.swift and its transport dependency. It checks receiver-name
constraints, secure-token format/distinctness, exact-token PIN/authentication and
Bonjour events, canonical nonzero Int32 errors, spoof/stale-input rejection,
fragmentation, line/ring bounds, parser recovery, and randomness-failure cleanup.

A tiny local C child exercises short status writes while the producer stays
alive, nonblocking/close-on-exec flags, owned-process stopping, final-event
draining, and safe randomness failure during final drain. The child contains no
AirPlay, networking, or window code. Five controller checks use the actual
failVideo and receive methods to verify stale failure rejection, immediate
session end, preserved failure messages through child exit, and one session-end
callback. Thirteen additional status-mailbox checks flood 10,000 genuine
status-shaped events while main delivery is blocked, verify latest-PIN
coalescing, terminal-failure/exit priority, stale and replaced runs, pending
event cancellation, and actual controller startup-to-exit cleanup. The mailbox
retains fixed slots and queues at most one main-thread drain. No actual
receiver, network service, or window is started. Three sidebar-readiness
checks reject stale/shutdown updates and verify that a current decoded-video
update clears the connection code before showing connected guidance.
Five separated-drain checks preserve policy/decoder failures and their useful
settings action across generic EOF and actual exit, and keep tracking a child
when Stop precedes delivery of its factual started event.

Compressed video transport: 94 checks

The runner tests the production IWV1 packet parser and private local socket
transport. Coverage includes bounded lengths/counts, fragmented/malformed input,
EOF/truncation, backpressure/failure handling, owned descriptor cleanup, and an
actual Process.standardInput socket inherited as child fd0. There is no network
listener, recording, receiver, or UI launch. See WIRELESS-VIDEO-TRANSPORT-TESTS.txt.

Synthetic H.264 parser/renderer: 53 checks

This suite requires macOS 14.4 or later, a logged-in graphical session, and access
to the system video codec service. A restricted execution sandbox may need
permission to use that codec service. It briefly opens a 384 x 256 window of
generated pixels; it captures no camera, screen, iPad, or network stream.

VideoToolbox encodes a real three-frame H.264 sequence with one IDR followed by
two dependent P frames. The production Annex-B parser/AVCC conversion and
renderer decode it until AVSampleBufferDisplayLayer is ready for display. Other
checks cover cached parameters, access-unit/parameter/NAL-count bounds, invalid
codec parameters, IDR recovery, stale/new/ended sessions, UI-event ordering,
reset-flood coalescing, and pending-event cancellation across session changes.

Manual scope

These suites do not establish AirPlay compatibility or Loom recording quality.
The user separately confirmed version 2.1 wireless video in the app's main
window, Clean View, and Loom's window preview with its camera bubble. USB video
had also been confirmed in earlier live testing. Rotation was not separately
verified, and no actual Loom recording or upload was performed by the agent.
See TEST-RESULTS.txt and the project's SECURITY-REVIEW.txt for scope.

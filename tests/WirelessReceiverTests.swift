// Appended to the unmodified production file by run_wireless_tests.py so these
// tests can exercise private helpers without changing their production access.
// This harness never creates a window or launches a receiver process.
private final class WirelessTestSuite {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() { passed += 1 } else { failures.append(name) }
    }
    func report() {
        if failures.isEmpty { print("PASS: \(passed) wireless security-boundary checks") }
        else {
            print("FAIL: \(failures.count) of \(passed + failures.count) wireless checks")
            for name in failures { print("FAILED CASE: " + name) }
            exit(1)
        }
    }
}

private final class CapturedWirelessEvents: @unchecked Sendable {
    var events: [WirelessEvent] = []
    var pins: [String] {
        events.compactMap { event in if case .challenge(let code) = event { return code }; return nil }
    }
    var authenticationCount: Int {
        events.filter { if case .authenticated = $0 { return true }; return false }.count
    }
    var failureCount: Int {
        events.filter { if case .failed = $0 { return true }; return false }.count
    }
    var bonjourReadyCount: Int {
        events.filter { if case .bonjourReady = $0 { return true }; return false }.count
    }
    var bonjourFailureCodes: [Int32] {
        events.compactMap { event in if case .bonjourFailed(let code) = event { return code }; return nil }
    }
}

@MainActor
private extension WirelessReceiverController {
    static func runNameTests(_ suite: WirelessTestSuite) {
        suite.check(sanitizedName("") == "iPad to Mac Mirroring", "empty name falls back to generic name")
        suite.check(sanitizedName(" ._-  ") == "iPad to Mac Mirroring", "punctuation-only name falls back")
        suite.check(sanitizedName("  Studio   iPad  ") == "Studio iPad", "spaces are normalized")
        suite.check(sanitizedName("-receiver") == "receiver", "name cannot begin as an option")
        suite.check(sanitizedName("Receiver;$(whoami)") == "Receiverwhoami", "shell punctuation is removed")
        suite.check(sanitizedName("<receiver>\n  two   spaces") == "receiver two spaces", "newline and markup are removed")
        suite.check(sanitizedName("A" + String(repeating: "B", count: 100)).utf8.count == 48,
                    "name stays within advertised ASCII byte limit")
        suite.check(sanitizedName("日本語😀") == "iPad to Mac Mirroring", "unsupported name characters fall back")
        let unusual = sanitizedName("../  A/B\\C\tD:123\"'  ._-  ")
        suite.check(!unusual.isEmpty && unusual.utf8.count <= 48 &&
                    unusual.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._-").contains($0) },
                    "unusual input retains only the documented name alphabet")
    }

    static func runVideoFailureTests(_ suite: WirelessTestSuite) {
        // Exercise the actual controller boundary without a view, browser,
        // receiver child, or video decoder. Owned-child exit is delivered as
        // the same private event the process host uses in production.
        let controller = WirelessReceiverController()
        let id = UUID()
        controller.currentRun = id
        controller.videoSessionID = id
        controller.wantsRunning = true
        controller.isRunning = true
        controller.receiverLaunchRequested = true
        var ended = 0
        controller.onVideoSessionEnd = { received in if received == id { ended += 1 } }
        controller.failVideo("Fixture video failure.", id: UUID())
        suite.check(controller.failureMessage == nil && ended == 0 && controller.wantsRunning,
                    "stale renderer failure cannot stop the current receiver")
        controller.failVideo("Fixture video failure.", id: id)
        suite.check(controller.presentationState.phase == .failed &&
                    controller.presentationState.message == "Fixture video failure." &&
                    !controller.wantsRunning && controller.isStopping,
                    "current renderer failure fails closed with its useful message")
        suite.check(ended == 1 && controller.videoSessionID == nil,
                    "renderer failure ends its video session immediately")
        controller.receive(id: id, event: .stopped(expected: true, status: 0))
        suite.check(controller.presentationState.phase == .failed &&
                    controller.presentationState.message == "Fixture video failure." &&
                    !controller.isRunning && !controller.isStopping && controller.currentRun == nil,
                    "expected child exit preserves the renderer failure")
        suite.check(ended == 1, "child exit does not end a video session twice")
    }

    static func runMailboxLifecycleTests(_ suite: WirelessTestSuite) {
        let controller = WirelessReceiverController()
        let id = UUID()
        controller.currentRun = id
        controller.videoSessionID = id
        controller.wantsRunning = true
        controller.isStarting = true
        controller.receiverLaunchRequested = true
        var ended = 0
        controller.onVideoSessionEnd = { received in if received == id { ended += 1 } }
        controller.statusMailbox.beginRun(id)
        for event: WirelessEvent in [.started, .bonjourReady, .challenge("0042"),
                                     .failed("Fixture mailbox failure."), .stopping,
                                     .stopped(expected: true, status: 1)] {
            controller.statusMailbox.enqueue(id: id, event: event)
        }
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while controller.currentRun != nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        suite.check(controller.presentationState.phase == .failed &&
                    controller.presentationState.message == "Fixture mailbox failure.",
                    "coalesced startup failure survives actual controller exit handling")
        suite.check(controller.currentRun == nil && !controller.isRunning && !controller.isStopping && ended == 1,
                    "coalesced startup-to-exit completes one controller session teardown")
    }

    static func runVideoReadyTests(_ suite: WirelessTestSuite) {
        let controller = WirelessReceiverController()
        let id = UUID()
        controller.currentRun = id
        controller.wantsRunning = true
        controller.isRunning = true
        controller.codeLabel.stringValue = "0042"
        let initialMessage = controller.presentationState.message
        controller.videoDidBecomeReady(id: UUID())
        suite.check(controller.presentationState.message == initialMessage && controller.codeLabel.stringValue == "0042",
                    "stale decoded-video readiness cannot change current sidebar state")
        controller.videoDidBecomeReady(id: id)
        suite.check(controller.presentationState.phase == .authenticated &&
                    controller.presentationState.message == "Mirroring your iPad in this window." &&
                    controller.codeLabel.stringValue == "— — — —" &&
                    !controller.codeHint.stringValue.contains("0042"),
                    "current decoded-video readiness updates sidebar without a PIN")
        controller.isStopping = true
        controller.present(.stopped, "Fixture stopping.")
        controller.videoDidBecomeReady(id: id)
        suite.check(controller.presentationState.phase == .stopped && controller.presentationState.message == "Fixture stopping.",
                    "decoded-video readiness cannot overwrite shutdown state")
    }

    static func runSeparatedStatusTests(_ suite: WirelessTestSuite) {
        func fresh() -> (WirelessReceiverController, UUID) {
            let controller = WirelessReceiverController()
            let id = UUID()
            controller.currentRun = id
            controller.videoSessionID = id
            controller.wantsRunning = true
            controller.isRunning = true
            controller.receiverLaunchRequested = true
            controller.statusMailbox.beginRun(id)
            return (controller, id)
        }
        func drainMain() {
            let deadline = Date(timeIntervalSinceNow: 0.06)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
        }
        let (policy, policyID) = fresh()
        policy.statusMailbox.enqueue(id: policyID, event: .bonjourFailed(-65570))
        drainMain()
        let usefulMessage = policy.presentationState.message
        policy.statusMailbox.enqueue(id: policyID, event: .failed("Fixture generic EOF."))
        drainMain()
        suite.check(policy.presentationState.message == usefulMessage && !policy.networkSettingsButton.isHidden &&
                    policy.currentRun == policyID && policy.isStopping,
                    "generic failure in a later drain preserves policy message and settings action")
        policy.statusMailbox.enqueue(id: policyID, event: .stopped(expected: true, status: 1))
        drainMain()
        suite.check(policy.presentationState.message == usefulMessage && !policy.networkSettingsButton.isHidden && policy.currentRun == nil,
                    "separated exit preserves the policy remedy and completes teardown")

        let (decoder, decoderID) = fresh()
        decoder.failVideo("Fixture useful decoder failure.", id: decoderID)
        decoder.statusMailbox.enqueue(id: decoderID, event: .failed("Fixture generic EOF."))
        drainMain()
        suite.check(decoder.presentationState.message == "Fixture useful decoder failure." && decoder.currentRun == decoderID,
                    "later generic EOF cannot overwrite a useful decoder failure")
        decoder.receive(id: decoderID, event: .stopped(expected: true, status: 1))

        let (stopping, stoppingID) = fresh()
        stopping.isRunning = false
        stopping.isStarting = true
        stopping.stop()
        stopping.statusMailbox.enqueue(id: stoppingID, event: .started)
        stopping.statusMailbox.enqueue(id: stoppingID, event: .failed("Fixture startup failure."))
        stopping.statusMailbox.enqueue(id: stoppingID, event: .stopping)
        drainMain()
        suite.check(stopping.currentRun == stoppingID && stopping.isRunning && stopping.isStopping && !stopping.startButton.isEnabled,
                    "Stop before started delivery keeps tracking the child until actual exit")
        stopping.statusMailbox.enqueue(id: stoppingID, event: .stopped(expected: true, status: 1))
        drainMain()
        suite.check(stopping.currentRun == nil && !stopping.isRunning && !stopping.isStopping && stopping.startButton.isEnabled,
                    "actual exit releases the stopped-before-started session exactly once")
    }
}

@MainActor
private extension WirelessStatusMailbox {
    static func runMailboxTests(_ suite: WirelessTestSuite) {
        var batches: [(UUID, [WirelessEvent])] = []
        let mailbox = WirelessStatusMailbox { id, events in batches.append((id, events)) }
        func drainMain() {
            let deadline = Date(timeIntervalSinceNow: 0.08)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
        }
        let id = UUID()
        mailbox.beginRun(id)
        let producerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            mailbox.enqueue(id: id, event: .started)
            mailbox.enqueue(id: id, event: .bonjourReady)
            for value in 0..<10_000 {
                mailbox.enqueue(id: id, event: .challenge(String(format: "%04d", value)))
            }
            producerFinished.signal()
        }
        suite.check(producerFinished.wait(timeout: .now() + 3) == .success,
                    "status flood producer completes while main delivery is blocked")
        suite.check(batches.isEmpty && mailbox.scheduled,
                    "status flood cannot deliver UI work while main is blocked")
        if case .challenge("9999") = mailbox.phase {
            suite.check(true, "blocked status mailbox retains only latest PIN")
        } else { suite.check(false, "blocked status mailbox retains only latest PIN") }
        drainMain()
        suite.check(batches.count == 1 && batches[0].1.count == 3,
                    "ten thousand challenges coalesce to one bounded delivery batch")
        if let events = batches.first?.1, events.count == 3,
           case .started = events[0], case .bonjourReady = events[1], case .challenge("9999") = events[2] {
            suite.check(true, "started and Bonjour readiness precede latest PIN")
        } else { suite.check(false, "started and Bonjour readiness precede latest PIN") }

        batches.removeAll()
        let terminalID = UUID()
        mailbox.beginRun(terminalID)
        mailbox.enqueue(id: terminalID, event: .started)
        mailbox.enqueue(id: terminalID, event: .bonjourReady)
        mailbox.enqueue(id: terminalID, event: .challenge("1111"))
        mailbox.enqueue(id: terminalID, event: .failed("Fixture EOF."))
        mailbox.enqueue(id: terminalID, event: .bonjourFailed(-65570))
        mailbox.enqueue(id: terminalID, event: .failed("Later generic failure."))
        mailbox.enqueue(id: terminalID, event: .stopping)
        mailbox.enqueue(id: terminalID, event: .stopped(expected: true, status: 1))
        mailbox.enqueue(id: terminalID, event: .challenge("2222"))
        mailbox.enqueue(id: terminalID, event: .authenticated)
        drainMain()
        suite.check(batches.count == 1 && batches[0].1.count == 4,
                    "terminal mailbox drops obsolete transient states and stays bounded")
        if let events = batches.first?.1, events.count == 4,
           case .started = events[0], case .bonjourFailed(-65570) = events[1],
           case .stopping = events[2], case .stopped(expected: true, status: 1) = events[3] {
            suite.check(true, "specific failure precedes stopping and exit")
        } else { suite.check(false, "specific failure precedes stopping and exit") }

        batches.removeAll()
        mailbox.beginRun(terminalID)
        mailbox.enqueue(id: terminalID, event: .failed("First useful failure."))
        mailbox.enqueue(id: terminalID, event: .failed("Later generic failure."))
        drainMain()
        if let event = batches.first?.1.first, case .failed("First useful failure.") = event {
            suite.check(true, "same-priority generic error cannot overwrite useful failure")
        } else { suite.check(false, "same-priority generic error cannot overwrite useful failure") }

        batches.removeAll()
        let replacementID = UUID()
        mailbox.beginRun(id)
        mailbox.enqueue(id: id, event: .challenge("1111"))
        mailbox.beginRun(replacementID)
        mailbox.endRun(id)
        mailbox.enqueue(id: id, event: .failed("Stale failure."))
        mailbox.enqueue(id: replacementID, event: .challenge("2222"))
        drainMain()
        suite.check(batches.count == 1 && batches[0].0 == replacementID,
                    "replacement run safely reuses pending drain and rejects stale run/end")
        if let event = batches.first?.1.first, case .challenge("2222") = event {
            suite.check(true, "replacement delivery contains no prior PIN or failure")
        } else { suite.check(false, "replacement delivery contains no prior PIN or failure") }

        batches.removeAll()
        mailbox.enqueue(id: replacementID, event: .challenge("3333"))
        mailbox.endRun(replacementID)
        mailbox.enqueue(id: replacementID, event: .authenticated)
        drainMain()
        suite.check(batches.isEmpty && !mailbox.scheduled && mailbox.activeID == nil,
                    "ended session discards pending and later status events")
    }
}

private extension WirelessProcessHost {
    static func runBoundaryTests(_ suite: WirelessTestSuite) throws {
        // Public fixtures, never actual receiver codes or session tokens.
        let fixtureToken = "ABCDEF12-3456-789A-BCDE-F1234567890A"
        let fixturePin = "0042"
        let fixtureLine = "IPADWINDOW_EVENT " + fixtureToken + " PIN " + fixturePin + "\n"
        func fresh() -> (WirelessProcessHost, CapturedWirelessEvents, UUID) {
            let record = CapturedWirelessEvents()
            let host = WirelessProcessHost { _, event in record.events.append(event) }
            let id = UUID()
            host.runID = id
            host.eventToken = fixtureToken
            return (host, record, id)
        }
        func rejects(_ input: String, _ name: String) {
            let (host, record, id) = fresh()
            host.consume(Data(input.utf8), id: id)
            suite.check(record.events.isEmpty, name)
        }
        do {
            let (host, record, id) = fresh()
            host.consume(Data(fixtureLine.utf8), id: id)
            suite.check(record.pins == [fixturePin], "valid exact-token PIN event is delivered")
            suite.check(!host.recentEvents.contains(where: { $0.contains(fixturePin) || $0.contains(fixtureToken) }),
                        "diagnostic ring does not retain codes or tokens")
        }
        rejects("*** CLIENT MUST NOW ENTER PIN = \"0042\" AS AIRPLAY PASSWORD\n",
                "legacy raw PIN log cannot drive the UI")
        rejects("Client authentication success\n", "raw authentication log cannot drive the UI")
        rejects("untrusted client\n*** CLIENT MUST NOW ENTER PIN = \"0042\" AS AIRPLAY PASSWORD\nClient authentication success\n",
                "client-name newline spoof cannot drive the UI")
        rejects(fixtureLine.replacingOccurrences(of: fixtureToken, with: "BBCDEF12-3456-789A-BCDE-F1234567890A"),
                "event from a different token is rejected")
        rejects("prefix " + fixtureLine, "event with a leading log prefix is rejected")
        rejects(fixtureLine.replacingOccurrences(of: "0042", with: "00421"), "overlong PIN is rejected")
        rejects(fixtureLine.replacingOccurrences(of: "0042", with: "042"), "short PIN is rejected")
        rejects(fixtureLine.replacingOccurrences(of: "0042", with: "00x2"), "nondigit PIN is rejected")
        rejects(fixtureLine.replacingOccurrences(of: "0042", with: "００４２"), "Unicode digit lookalikes are rejected")
        rejects(fixtureLine.replacingOccurrences(of: "\n", with: " trailing\n"), "trailing PIN data is rejected")
        rejects(fixtureLine.replacingOccurrences(of: "\n", with: "\r\n"), "unexpected carriage return is rejected")
        rejects("IPADWINDOW_EVENT " + fixtureToken + " UNKNOWN\n", "unknown machine event is rejected")
        let readyLine = "IPADWINDOW_EVENT " + fixtureToken + " BONJOUR_READY\n"
        let failedPrefix = "IPADWINDOW_EVENT " + fixtureToken + " BONJOUR_FAILED "
        do {
            let (host, record, id) = fresh()
            host.consume(Data(readyLine.utf8), id: id)
            suite.check(record.bonjourReadyCount == 1 && record.bonjourFailureCodes.isEmpty && record.pins.isEmpty,
                        "exact Bonjour-ready event is delivered separately")
        }
        for (value, expected) in [("-65570", Int32(-65570)), ("65570", Int32(65570)),
                                  ("-2147483648", Int32.min), ("2147483647", Int32.max)] {
            let (host, record, id) = fresh()
            host.consume(Data((failedPrefix + value + "\n").utf8), id: id)
            suite.check(record.bonjourFailureCodes == [expected] && record.bonjourReadyCount == 0 && record.pins.isEmpty,
                        "canonical nonzero Bonjour status is accepted: " + (expected == Int32.min ? "minimum" : expected == Int32.max ? "maximum" : expected < 0 ? "negative" : "positive"))
        }
        rejects("BONJOUR_READY\nBONJOUR_FAILED -65570\n", "raw Bonjour-looking logs cannot drive the UI")
        rejects("untrusted client\nIPADWINDOW_EVENT BBCDEF12-3456-789A-BCDE-F1234567890A BONJOUR_READY\n",
                "client-name newline spoof without this-run token cannot mark Bonjour ready")
        rejects(readyLine.replacingOccurrences(of: fixtureToken, with: "BBCDEF12-3456-789A-BCDE-F1234567890A"),
                "wrong-token Bonjour-ready event is rejected")
        rejects((failedPrefix + "-65570\n").replacingOccurrences(of: fixtureToken, with: "BBCDEF12-3456-789A-BCDE-F1234567890A"),
                "wrong-token Bonjour-failure event is rejected")
        rejects("prefix " + readyLine, "prefixed Bonjour-ready log is rejected")
        rejects(readyLine.replacingOccurrences(of: "\n", with: " trailing\n"), "trailing Bonjour-ready data is rejected")
        rejects("IPADWINDOW_EVENT " + fixtureToken + " BONJOUR_UNKNOWN\n", "unknown Bonjour machine event is rejected")
        for (value, name) in [("0", "zero"), ("-0", "negative zero"), ("+1", "explicit plus sign"),
                              ("065570", "leading zero"), ("-065570", "negative leading zero"),
                              ("", "empty"), (" -65570", "leading space"), ("-65570 ", "trailing space"),
                              ("-65570 trailing", "trailing text"), ("0x10", "hex notation"),
                              ("1e2", "exponent notation"), ("−65570", "Unicode minus"),
                              ("６５５７０", "Unicode digits"), ("2147483648", "positive overflow"),
                              ("-2147483649", "negative overflow"),
                              (String(repeating: "9", count: 100), "excessive numeric length")] {
            rejects(failedPrefix + value + "\n", "noncanonical Bonjour status is rejected: " + name)
        }
        do {
            let (host, record, id) = fresh()
            let combined = readyLine + failedPrefix + "-65570\n"
            for byte in combined.utf8 { host.consume(Data([byte]), id: id) }
            suite.check(record.bonjourReadyCount == 1 && record.bonjourFailureCodes == [-65570],
                        "fragmented Bonjour events reassemble without changing their types")
        }
        do {
            let bytes = Array((failedPrefix + "-65570\n").utf8)
            var allSplitsPass = true
            for split in 0...bytes.count {
                let (host, record, id) = fresh()
                host.consume(Data(bytes.prefix(split)), id: id)
                host.consume(Data(bytes.dropFirst(split)), id: id)
                allSplitsPass = allSplitsPass && record.bonjourFailureCodes == [-65570]
            }
            suite.check(allSplitsPass, "every two-chunk split preserves a canonical Bonjour failure")
        }
        do {
            let (host, record, _) = fresh()
            host.consume(Data((readyLine + failedPrefix + "-65570\n").utf8), id: UUID())
            suite.check(record.events.isEmpty, "stale-run Bonjour events are rejected")
        }
        do {
            let (host, record, id) = fresh()
            host.stopping = true
            host.consume(Data((readyLine + failedPrefix + "-65570\n").utf8), id: id)
            suite.check(record.events.isEmpty, "Bonjour events are rejected during stop")
        }
        do {
            let (host, record, id) = fresh()
            let bytes = Array(fixtureLine.utf8)
            for byte in bytes.dropLast() { host.consume(Data([byte]), id: id) }
            suite.check(record.events.isEmpty, "unterminated fragments produce no event")
            host.consume(Data([10]), id: id)
            suite.check(record.pins == [fixturePin], "one-byte fragments reassemble correctly")
        }
        do {
            let bytes = Array(fixtureLine.utf8)
            var allSplitsPass = true
            for split in 0...bytes.count {
                let (host, record, id) = fresh()
                host.consume(Data(bytes.prefix(split)), id: id)
                host.consume(Data(bytes.dropFirst(split)), id: id)
                allSplitsPass = allSplitsPass && record.pins == [fixturePin]
            }
            suite.check(allSplitsPass, "every two-chunk split preserves one valid event")
        }
        do {
            let (host, record, id) = fresh()
            host.consume(Data(fixtureLine.utf8), id: UUID())
            suite.check(record.events.isEmpty, "stale run callback is rejected")
            host.consume(Data(fixtureLine.utf8), id: id)
            suite.check(record.pins == [fixturePin], "current run remains functional after stale input")
        }
        do {
            let (host, record, id) = fresh()
            host.stopping = true
            host.consume(Data(fixtureLine.utf8), id: id)
            suite.check(record.events.isEmpty, "code events are rejected during stop")
        }
        do {
            let (host, record, id) = fresh()
            host.eventToken = nil
            host.consume(Data(fixtureLine.utf8), id: id)
            suite.check(record.events.isEmpty, "code events require an active token")
        }
        do {
            let (host, record, id) = fresh()
            host.consume(Data(repeating: 120, count: 1_000_000), id: id)
            suite.check(host.partialLine.count <= 1024 && host.discardingLongLine,
                        "unterminated untrusted output stays bounded")
            host.consume(Data(fixtureLine.utf8), id: id)
            suite.check(record.events.isEmpty, "token-looking suffix of discarded long line is rejected")
            host.consume(Data(fixtureLine.utf8), id: id)
            suite.check(record.pins == [fixturePin], "parser recovers on next complete bounded line")
        }
        do {
            let (host, record, id) = fresh()
            host.consume(Data([0xFF, 0xFE, 10]), id: id)
            suite.check(record.events.isEmpty, "invalid UTF-8 is rejected")
            host.consume(Data(("IPADWINDOW_EVENT " + fixtureToken + " AUTHENTICATED\n").utf8), id: id)
            suite.check(record.authenticationCount == 1 && record.pins.isEmpty,
                        "exact authentication event is delivered separately")
        }
        do {
            let (host, record, id) = fresh()
            host.consume(Data(("IPADWINDOW_EVENT " + fixtureToken + " RNG_FAILED\n" + fixtureLine + readyLine).utf8), id: id)
            suite.check(record.failureCount == 1 && record.pins.isEmpty && record.bonjourReadyCount == 0 && host.eventToken == nil,
                        "randomness failure stops and clears authentication before later input")
        }
        do {
            let (host, _, _) = fresh()
            for index in 0..<100 { host.remember("Fixture event " + String(index)) }
            suite.check(host.recentEvents.count == 32, "redacted event ring stays bounded")
        }
        var tokens = Set<String>()
        var validTokenShapes = true
        for _ in 0..<32 {
            let token = try newEventToken()
            validTokenShapes = validTokenShapes && token.utf8.count == 36 && UUID(uuidString: token) != nil
            tokens.insert(token)
        }
        suite.check(validTokenShapes, "generated tokens match bounded machine-event contract")
        suite.check(tokens.count == 32, "successive secure token requests are distinct")
    }
}

private let wirelessTestSuite = WirelessTestSuite()
do {
    try WirelessProcessHost.runBoundaryTests(wirelessTestSuite)
    guard CommandLine.arguments.count == 2 else {
        print("FAIL: local IPC fixture resources were not provided")
        exit(1)
    }
    WirelessProcessHost.runIPCTests(wirelessTestSuite, resources: URL(fileURLWithPath: CommandLine.arguments[1]))
    MainActor.assumeIsolated {
        WirelessReceiverController.runNameTests(wirelessTestSuite)
        WirelessReceiverController.runVideoFailureTests(wirelessTestSuite)
        WirelessReceiverController.runMailboxLifecycleTests(wirelessTestSuite)
        WirelessReceiverController.runVideoReadyTests(wirelessTestSuite)
        WirelessReceiverController.runSeparatedStatusTests(wirelessTestSuite)
        WirelessStatusMailbox.runMailboxTests(wirelessTestSuite)
    }
    wirelessTestSuite.report()
} catch {
    print("FAIL: secure-token generation was unavailable during test run")
    exit(1)
}

// Same-file extensions test the actual production DispatchSource/POSIX reader
// against a tiny local fixture process. No receiver, window, or network starts.
private final class WirelessIPCRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WirelessEvent] = []
    let ready = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    func add(_ event: WirelessEvent) {
        lock.lock(); stored.append(event); lock.unlock()
        if case .bonjourReady = event { ready.signal() }
        if case .stopped = event { stopped.signal() }
    }
    var events: [WirelessEvent] { lock.lock(); defer { lock.unlock() }; return stored }
}

private extension WirelessProcessHost {
    static func runIPCTests(_ suite: WirelessTestSuite, resources: URL) {
        // A small write must be delivered while the producer remains alive;
        // waiting for 4096 bytes or EOF would fail this test.
        do {
            let record = WirelessIPCRecord()
            let host = WirelessProcessHost { _, event in record.add(event) }
            host.start(id: UUID(), receiverName: "IPC_RUNNING", resources: resources)
            let receivedPromptly = record.ready.wait(timeout: .now() + 3) == .success
            suite.check(receivedPromptly, "IPC small live write is delivered without EOF or a full buffer")
            let flagsValid = host.queue.sync { () -> Bool in
                guard host.outputReadFD >= 0 else { return false }
                let status = Darwin.fcntl(host.outputReadFD, F_GETFL)
                let descriptor = Darwin.fcntl(host.outputReadFD, F_GETFD)
                return status >= 0 && descriptor >= 0 && status & O_NONBLOCK != 0 && descriptor & FD_CLOEXEC != 0
            }
            suite.check(flagsValid, "IPC reader descriptor is nonblocking and closes on exec")
            suite.check(!record.events.contains { if case .stopped = $0 { return true }; return false },
                        "IPC ready event arrives before the long-running producer exits")
            let completion = DispatchSemaphore(value: 0)
            host.stop { completion.signal() }
            suite.check(completion.wait(timeout: .now() + 6) == .success,
                        "IPC owned long-running producer stops and completes cleanup")
            let stopped = record.events.filter { if case .stopped = $0 { return true }; return false }
            suite.check(stopped.count == 1, "IPC normal stop produces one terminal event")
        }

        // Hold the serial queue until the short producer has exited. Its source
        // handler cannot run first: didExit must itself drain the final event.
        for mode in ["IPC_IMMEDIATE", "IPC_RNG_EXIT"] {
            let record = WirelessIPCRecord()
            let host = WirelessProcessHost { _, event in record.add(event) }
            let setupFinished = DispatchSemaphore(value: 0)
            let fixture = resources.appendingPathComponent("Wireless/bin/uxplay")
            host.queue.async {
                defer { setupFinished.signal() }
                let id = UUID()
                let token = "ABCDEF12-3456-789A-BCDE-F1234567890A"
                host.runID = id
                host.eventToken = token
                let child = Process()
                let pipe = Pipe()
                child.executableURL = fixture
                child.arguments = ["-n", mode]
                child.environment = ["IPAD_WINDOW_EVENT_TOKEN": token]
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = pipe
                child.standardError = pipe
                host.outputPipe = pipe
                do {
                    try host.installOutputReader(pipe: pipe, id: id)
                    host.process = child
                    try child.run()
                    try? pipe.fileHandleForWriting.close()
                    try? pipe.fileHandleForReading.close()
                    child.waitUntilExit()
                    host.didExit(child, id: id)
                } catch {
                    host.process = nil
                    host.cleanup()
                }
            }
            suite.check(setupFinished.wait(timeout: .now() + 5) == .success,
                        mode == "IPC_RNG_EXIT" ? "IPC RNG-exit fixture completes" : "IPC immediate-exit fixture completes")
            let events = record.events
            let terminalCount = events.filter { if case .stopped = $0 { return true }; return false }.count
            suite.check(terminalCount == 1,
                        mode == "IPC_RNG_EXIT" ? "IPC RNG final drain cannot re-enter terminal cleanup" : "IPC immediate exit produces one terminal event")
            if mode == "IPC_RNG_EXIT" {
                suite.check(events.contains { if case .failed = $0 { return true }; return false },
                            "IPC final RNG failure is delivered before teardown")
            } else {
                let failureIndex = events.firstIndex { if case .bonjourFailed(-65570) = $0 { return true }; return false }
                let stoppedIndex = events.firstIndex { if case .stopped = $0 { return true }; return false }
                suite.check(failureIndex != nil && stoppedIndex != nil && failureIndex! < stoppedIndex!,
                            "IPC final short failure is drained before the exit event")
            }
            let clean = host.queue.sync {
                host.process == nil && host.runID == nil && host.outputSource == nil &&
                    host.outputReadFD == -1 && host.eventToken == nil && !host.finishingExit
            }
            suite.check(clean, "IPC exited producer leaves no active reader or run state")
        }
    }
}

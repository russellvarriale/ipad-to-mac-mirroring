// Copyright (c) 2026 Russell Varriale (https://github.com/russellvarriale/ipad-to-mac-mirroring)
// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import Darwin
import Security
@preconcurrency import Network

private enum WirelessEvent: Sendable {
    case started
    case bonjourReady
    case bonjourFailed(Int32)
    case challenge(String)
    case authenticated
    case stopping
    case stopped(expected: Bool, status: Int32)
    case failed(String)
}

// Authentication attempts can generate genuine status events before a client
// authenticates. Bound UI delivery as well as raw output: at most one main
// drain is queued, and only the latest transient state/PIN is retained.
private final class WirelessStatusMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let deliver: @MainActor @Sendable (UUID, [WirelessEvent]) -> Void
    private var activeID: UUID?
    private var scheduled = false
    private var started = false
    private var ready = false
    private var phase: WirelessEvent?
    private var failure: WirelessEvent?
    private var stopping = false
    private var stopped: WirelessEvent?

    init(deliver: @escaping @MainActor @Sendable (UUID, [WirelessEvent]) -> Void) {
        self.deliver = deliver
    }

    func beginRun(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        activeID = id
        clearPending()
        // An old queued drain continues to own scheduled until it executes;
        // it can safely deliver this new run's bounded pending state instead.
    }

    func endRun(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard activeID == id else { return }
        activeID = nil
        clearPending()
    }

    func enqueue(id: UUID, event: WirelessEvent) {
        lock.lock(); defer { lock.unlock() }
        guard activeID == id else { return }
        switch event {
        case .started:
            if failure == nil && !stopping && stopped == nil { started = true }
        case .bonjourReady:
            if failure == nil && !stopping && stopped == nil { ready = true }
        case .challenge, .authenticated:
            if failure == nil && !stopping && stopped == nil { phase = event }
        case .bonjourFailed, .failed:
            // A concrete registration error is more useful than an EOF caused
            // by that same failure. Otherwise retain the first useful failure.
            if failure == nil || (isBonjourFailure(event) && !isBonjourFailure(failure!)) {
                failure = event
            }
            ready = false
            phase = nil
        case .stopping:
            stopping = true
            ready = false
            phase = nil
        case .stopped:
            if stopped == nil { stopped = event }
            ready = false
            phase = nil
        }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func isBonjourFailure(_ event: WirelessEvent) -> Bool {
        if case .bonjourFailed = event { return true }
        return false
    }

    // All callers hold lock. These fixed slots cannot grow with producer rate.
    private func clearPending() {
        started = false
        ready = false
        phase = nil
        failure = nil
        stopping = false
        stopped = nil
    }

    @MainActor private func drain() {
        lock.lock()
        let id = activeID
        var events: [WirelessEvent] = []
        if started { events.append(.started) }
        if ready { events.append(.bonjourReady) }
        if let phase { events.append(phase) }
        if let failure { events.append(failure) }
        if stopping { events.append(.stopping) }
        if let stopped { events.append(stopped) }
        clearPending()
        scheduled = false
        lock.unlock()
        guard let id, !events.isEmpty else { return }
        deliver(id, events)
    }
}

// This object owns exactly one bundled receiver child. All process state,
// cleanup, output parsing, and signals are confined to its serial queue.
private final class WirelessProcessHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.ipadwindow.wireless", qos: .userInitiated)
    private var process: Process?
    private var videoTransport: WirelessVideoTransport?
    private var runID: UUID?
    private var outputPipe: Pipe?
    private var outputSource: DispatchSourceRead?
    private var outputSourceID: UUID?
    private var outputReadFD: Int32 = -1
    private var finishingExit = false
    private var scratchDirectory: URL?
    private var eventToken: String?
    private var stopping = false
    private var stopCallbacks: [@Sendable () -> Void] = []
    private var partialLine = Data()
    private var discardingLongLine = false
    // Only constant, redacted event descriptions enter this bounded ring.
    // Raw child output and connection codes are never retained as diagnostics.
    private var recentEvents: [String] = []
    private let eventHandler: @Sendable (UUID, WirelessEvent) -> Void

    init(eventHandler: @escaping @Sendable (UUID, WirelessEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    func start(id: UUID, receiverName: String, resources: URL,
               receiveVideo: (@Sendable (WirelessVideoPacket) -> Bool)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.process == nil else {
                self.eventHandler(id, .failed("The previous receiver is still stopping. Try again in a moment."))
                return
            }
            self.runID = id
            self.stopping = false
            self.recentEvents.removeAll(keepingCapacity: true)
            self.partialLine.removeAll(keepingCapacity: true)
            self.discardingLongLine = false
            do {
                let root = resources.appendingPathComponent("Wireless", isDirectory: true).resolvingSymlinksInPath()
                let executable = root.appendingPathComponent("bin/uxplay").resolvingSymlinksInPath()
                guard executable.path.hasPrefix(root.path + "/"),
                      FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw WirelessLaunchFailure.missingBackend
                }
                let plugins = root.appendingPathComponent("lib/gstreamer-1.0", isDirectory: true)
                guard FileManager.default.fileExists(atPath: plugins.path) else {
                    throw WirelessLaunchFailure.missingBackend
                }
                let token = try Self.newEventToken()
                self.eventToken = token
                let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("iPadWindow-Wireless-" + id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                self.scratchDirectory = scratch
                let child = Process()
                child.executableURL = executable
                child.currentDirectoryURL = scratch
                // No shell, user configuration, persistent pairing register,
                // private-key file, debug logs, recording, or arbitrary pipeline.
                // -pw without a value requests a fresh code for every connection.
                // -m without a value creates a fresh receiver identity per Start.
                child.arguments = ["-n", receiverName, "-nh", "-pw", "-m",
                                   "-as", "0", "-vsync", "no", "-vs", "glimagesink",
                                   "-s", "1920x1440", "-fps", "60", "-nofreeze", "-nc", "no",
                                   "-rc", "/dev/null"]
                // Deliberately construct rather than inherit the environment.
                // HOME is not changed; explicit config/cache paths isolate the
                // receiver from the user's UxPlay and GStreamer configuration.
                child.environment = [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "en_US.UTF-8",
                    "LC_ALL": "C",
                    "TMPDIR": scratch.path,
                    "XDG_CACHE_HOME": scratch.appendingPathComponent("cache").path,
                    "XDG_CONFIG_HOME": scratch.appendingPathComponent("config").path,
                    "GSETTINGS_BACKEND": "memory",
                    "GST_PLUGIN_SYSTEM_PATH_1_0": plugins.path,
                    "GST_PLUGIN_SYSTEM_PATH": plugins.path,
                    "GST_PLUGIN_PATH_1_0": "",
                    "GST_PLUGIN_PATH": "",
                    "GST_REGISTRY": scratch.appendingPathComponent("gst-registry.bin").path,
                    "GST_REGISTRY_FORK": "no",
                    "GST_DEBUG": "0",
                    "GST_DEBUG_NO_COLOR": "1",
                    "UXPLAYRC": "/dev/null",
                    "IPAD_WINDOW_EVENT_TOKEN": token
                ]
                if let receiveVideo {
                    let transport = try WirelessVideoTransport(receive: receiveVideo, failed: { [weak self] message in
                        self?.queue.async { [weak self] in
                            guard let self, self.runID == id, !self.stopping else { return }
                            self.eventHandler(id, .failed(message))
                            self.stopOnQueue()
                        }
                    })
                    self.videoTransport = transport
                    child.standardInput = transport.childInput
                    child.environment?["IPAD_WINDOW_EMBEDDED_VIDEO"] = "1"
                } else {
                    child.standardInput = FileHandle.nullDevice
                }
                let pipe = Pipe()
                child.standardOutput = pipe
                child.standardError = pipe
                self.outputPipe = pipe
                try self.installOutputReader(pipe: pipe, id: id)
                child.terminationHandler = { [weak self, weak child] _ in
                    guard let child else { return }
                    self?.queue.async { [weak self] in
                        self?.didExit(child, id: id)
                    }
                }
                self.process = child
                do { try child.run() }
                catch {
                    self.process = nil
                    throw error
                }
                self.videoTransport?.closeChildEndAfterSpawn()
                // The child now owns its duplicated stdout/stderr descriptors.
                // Keeping a parent writer open would prevent EOF on child exit.
                try? pipe.fileHandleForWriting.close()
                try? pipe.fileHandleForReading.close()
                self.remember("Receiver process started")
                self.eventHandler(id, .started)
            } catch {
                self.cleanup()
                self.runID = nil
                let message: String
                switch error as? WirelessLaunchFailure {
                case .missingBackend:
                    message = "The bundled wireless receiver is missing or incomplete. Rebuild or reinstall this app."
                case .randomnessUnavailable:
                    message = "A secure receiver session could not be created. The wireless receiver was not started."
                default:
                    message = "The bundled receiver could not start. Close other AirPlay receivers and try again."
                }
                self.eventHandler(id, .failed(message))
                self.finishStopCallbacks()
            }
        }
    }

    private func installOutputReader(pipe: Pipe, id: UUID) throws {
        let fd = Darwin.dup(pipe.fileHandleForReading.fileDescriptor)
        guard fd >= 0 else { throw WirelessLaunchFailure.statusChannelUnavailable }
        let flags = Darwin.fcntl(fd, F_GETFL)
        let descriptorFlags = Darwin.fcntl(fd, F_GETFD)
        guard flags >= 0, descriptorFlags >= 0,
              Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0,
              Darwin.fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) >= 0 else {
            Darwin.close(fd)
            throw WirelessLaunchFailure.statusChannelUnavailable
        }
        let sourceID = UUID()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        outputReadFD = fd
        outputSourceID = sourceID
        outputSource = source
        source.setEventHandler { [weak self] in
            self?.drainOutput(id: id, sourceID: sourceID, fd: fd, maximumReads: 8)
        }
        // This is the only owner that closes the duplicated descriptor. A stale
        // event cannot access a newer run because both source/run IDs are checked.
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    private func drainOutput(id: UUID, sourceID: UUID, fd: Int32, maximumReads: Int) {
        guard runID == id, outputSourceID == sourceID, outputReadFD == fd else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Read only available bytes, with a fixed work bound per queue turn.
        // No blocking FileHandle reads or queued raw-output chunks are involved.
        for _ in 0..<maximumReads {
            guard runID == id, outputSourceID == sourceID, outputReadFD == fd else { return }
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!, buffer.count)
            }
            if count > 0 {
                consume(Data(bytes.prefix(count)), id: id)
            } else if count == 0 {
                cancelOutputReader()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                cancelOutputReader()
                eventHandler(id, .failed("The receiver status channel failed. The receiver has been stopped."))
                stopOnQueue()
                return
            }
        }
    }

    private func cancelOutputReader() {
        outputSource?.cancel()
        outputSource = nil
        outputSourceID = nil
        outputReadFD = -1
    }

    private static func newEventToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw WirelessLaunchFailure.randomnessUnavailable }
        // Preserve all 128 random bits; UUID is used only for bounded formatting.
        let token = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
        guard token.utf8.count == 36,
              token.utf8.enumerated().allSatisfy({ index, byte in
                  if [8, 13, 18, 23].contains(index) { return byte == 45 }
                  return (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              }) else { throw WirelessLaunchFailure.randomnessUnavailable }
        return token
    }

    private func remember(_ message: String) {
        if recentEvents.last != message { recentEvents.append(message) }
        if recentEvents.count > 32 { recentEvents.removeFirst(recentEvents.count - 32) }
    }

    private func consume(_ chunk: Data, id: UUID) {
        // Bound a partially received line too. Long lines are discarded in full;
        // their suffix cannot accidentally be interpreted as a trusted message.
        for byte in chunk {
            if byte == 10 {
                if !discardingLongLine { consumeLine(partialLine, id: id) }
                partialLine.removeAll(keepingCapacity: true)
                discardingLongLine = false
            } else if !discardingLongLine {
                if partialLine.count < 1024 { partialLine.append(byte) }
                else { partialLine.removeAll(keepingCapacity: true); discardingLongLine = true }
            }
        }
    }

    private func consumeLine(_ bytes: Data, id: UUID) {
        guard runID == id, !stopping, let token = eventToken,
              let line = String(data: bytes, encoding: .utf8) else { return }
        // Client-controlled names can contain newlines. Accept only dedicated
        // machine events carrying this run's unpredictable private token, never
        // human-readable receiver logs or arbitrary four-digit strings.
        let prefix = "IPADWINDOW_EVENT " + token + " "
        let pinPrefix = prefix + "PIN "
        if line.hasPrefix(pinPrefix) {
            let code = String(line.dropFirst(pinPrefix.count))
            if code.utf8.count == 4 && code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
                remember("Connection code requested")
                eventHandler(id, .challenge(code))
            }
        } else if line == prefix + "AUTHENTICATED" {
            remember("Connection authenticated")
            eventHandler(id, .authenticated)
        } else if line == prefix + "BONJOUR_READY" {
            remember("Bonjour services registered")
            eventHandler(id, .bonjourReady)
        } else if line.hasPrefix(prefix + "BONJOUR_FAILED ") {
            let value = String(line.dropFirst((prefix + "BONJOUR_FAILED ").count))
            // Only a canonical, nonzero Int32 status can enter the UI. Never
            // display arbitrary receiver output as a discovery error.
            if value.utf8.count <= 11, let code = Int32(value), code != 0,
               String(code) == value {
                remember("Bonjour registration failed")
                eventHandler(id, .bonjourFailed(code))
            }
        } else if line == prefix + "RNG_FAILED" {
            remember("Authentication randomness failed; receiver stopped")
            eventHandler(id, .failed("A secure connection code could not be generated. The receiver has been stopped."))
            stopOnQueue()
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { completion?(); return }
            if let completion { self.stopCallbacks.append(completion) }
            self.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        guard let child = process, let id = runID else {
            cleanup()
            finishStopCallbacks()
            return
        }
        guard !stopping else { return }
        stopping = true
        // Stop video work and mark its EOF as expected before terminating the
        // child. Cleanup repeats this safely after the owned process exits.
        videoTransport?.stop()
        remember("Receiver stop requested")
        eventHandler(id, .stopping)
        if child.isRunning { child.terminate() }
        else { didExit(child, id: id); return }
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak child] in
            guard let self, let child, self.process === child,
                  self.runID == id, self.stopping, child.isRunning,
                  child.processIdentifier > 0 else { return }
            // Signal only this still-running owned child, never a name search,
            // broad kill command, guessed PID, or unrelated receiver process.
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
    }

    private func didExit(_ child: Process, id: UUID) {
        guard process === child, runID == id, !finishingExit else { return }
        finishingExit = true
        // Process termination can reach this queue before the read source's last
        // event. Drain the bounded, nonblocking pipe before clearing its run/token.
        // The finishing guard also prevents RNG_FAILED from re-entering didExit.
        if let sourceID = outputSourceID, outputReadFD >= 0 {
            drainOutput(id: id, sourceID: sourceID, fd: outputReadFD, maximumReads: 32)
        }
        let expected = stopping
        let status = child.terminationStatus
        process = nil
        runID = nil
        cleanup()
        remember(expected ? "Receiver stopped" : "Receiver exited")
        eventHandler(id, .stopped(expected: expected, status: status))
        finishStopCallbacks()
    }

    private func cleanup() {
        videoTransport?.stop()
        videoTransport = nil
        cancelOutputReader()
        try? outputPipe?.fileHandleForReading.close()
        try? outputPipe?.fileHandleForWriting.close()
        outputPipe = nil
        partialLine.removeAll(keepingCapacity: false)
        discardingLongLine = false
        if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
        scratchDirectory = nil
        eventToken = nil
        stopping = false
        finishingExit = false
    }

    private func finishStopCallbacks() {
        let callbacks = stopCallbacks
        stopCallbacks.removeAll()
        callbacks.forEach { $0() }
    }
}

private enum WirelessLaunchFailure: Error, Equatable { case missingBackend, randomnessUnavailable, statusChannelUnavailable }

struct WirelessPresentationState: Sendable {
    enum Phase: Sendable {
        case stopped, starting, listening, challenge, authenticated, failed
    }
    let phase: Phase
    let message: String
}

@MainActor
private final class WirelessSidebarDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class WirelessReceiverController: NSObject {
    private var sidebarView: NSView?
    var view: NSView { makeView() }
    var onPresentationChange: ((WirelessPresentationState) -> Void)?
    var onVideoSessionStart: ((UUID) -> Void)?
    var onVideoSessionEnd: ((UUID) -> Void)?
    var onVideoPacket: (@Sendable (UUID, WirelessVideoPacket) -> Bool)?
    private(set) var presentationState = WirelessPresentationState(
        phase: .stopped, message: "Start to mirror your iPad over Wi-Fi.")

    private let nameField = NSTextField(string: "iPad to Mac Mirroring")
    private let startButton = NSButton(title: "Start Wireless", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "Start to mirror your iPad over Wi-Fi.")
    private let codeLabel = NSTextField(labelWithString: "— — — —")
    private let codeHint = NSTextField(wrappingLabelWithString: "A connection code appears here when your iPad asks to connect.")
    private let networkSettingsButton = NSButton(title: "Open Local Network Settings", target: nil, action: nil)
    private var currentRun: UUID?
    private var videoSessionID: UUID?
    private var permissionBrowser: NWBrowser?
    private var receiverLaunchRequested = false
    private var wantsRunning = false
    private var isStopping = false
    private var failureMessage: String?
    private(set) var isRunning = false
    private(set) var isStarting = false
    private lazy var statusMailbox = WirelessStatusMailbox { [weak self] id, events in
        for event in events { self?.receive(id: id, event: event) }
    }
    private lazy var host: WirelessProcessHost = {
        let mailbox = statusMailbox
        return WirelessProcessHost { id, event in mailbox.enqueue(id: id, event: event) }
    }()

    @discardableResult
    func makeView() -> NSView {
        if let sidebarView { return sidebarView }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let document = WirelessSidebarDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let title = NSTextField(labelWithString: "Wireless")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let introduction = label("Connect your Mac and iPad to the same trusted Wi-Fi network.")
        let nameLabel = NSTextField(labelWithString: "Receiver name")
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameField.placeholderString = "iPad to Mac Mirroring"
        nameField.font = .systemFont(ofSize: 13)
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(toggle)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.isSelectable = false
        codeHint.font = .systemFont(ofSize: 11)
        codeHint.textColor = .secondaryLabelColor
        codeHint.alignment = .center
        codeHint.maximumNumberOfLines = 0
        networkSettingsButton.target = self
        networkSettingsButton.action = #selector(openLocalNetworkSettings)
        networkSettingsButton.isHidden = true
        let instructions = label("1. Click Start Wireless.\n2. On your iPad, open Control Center → Screen Mirroring and select the receiver name.\n3. Enter the code shown here.\n4. Record this window in your recording app with your Mac camera.")
        let note = label("Video only. Use your recording app for your camera and microphone. Hiding this sidebar keeps mirroring on; Stop ends the receiver.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, introduction, nameLabel, nameField, startButton,
                                       statusLabel, networkSettingsButton, codeLabel, codeHint, instructions, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
        for field in [introduction, nameField, statusLabel, codeLabel, codeHint, instructions, note] {
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        startButton.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        networkSettingsButton.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sidebarView = scroll
        updateControls()
        return scroll
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.maximumNumberOfLines = 0
        field.font = .systemFont(ofSize: 12)
        return field
    }

    private func present(_ phase: WirelessPresentationState.Phase, _ message: String) {
        presentationState = WirelessPresentationState(phase: phase, message: message)
        statusLabel.stringValue = message
        onPresentationChange?(presentationState)
    }

    private func endVideoSession() {
        guard let id = videoSessionID else { return }
        videoSessionID = nil
        onVideoSessionEnd?(id)
    }

    private static func sanitizedName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._-")
        let characters = name.unicodeScalars.filter { allowed.contains($0) }
        let filtered = String(String.UnicodeScalarView(characters))
        let collapsed = filtered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        return trimmed.isEmpty ? "iPad to Mac Mirroring" : String(trimmed.prefix(48))
    }

    @objc private func toggle() {
        if wantsRunning || isRunning || isStarting { stop() }
        else { start() }
    }

    func start() {
        guard !wantsRunning, !isRunning, !isStarting, !isStopping else { return }
        guard let videoReceiver = onVideoPacket else {
            present(.failed, "The video viewer is not ready. Try again after reopening the app.")
            return
        }
        guard let resources = Bundle.main.resourceURL else {
            present(.failed, "This app’s receiver resources are unavailable.")
            return
        }
        let name = Self.sanitizedName(nameField.stringValue)
        nameField.stringValue = name
        let id = UUID()
        currentRun = id
        statusMailbox.beginRun(id)
        wantsRunning = true
        isStarting = true
        receiverLaunchRequested = false
        failureMessage = nil
        networkSettingsButton.isHidden = true
        clearCode()
        videoSessionID = id
        onVideoSessionStart?(id)
        present(.starting, "Checking local network access… Allow access if macOS asks.")
        updateControls()
        beginNetworkPreflight(id: id, receiverName: name, resources: resources, receiveVideo: videoReceiver)
    }

    func stop() {
        guard wantsRunning || isRunning || isStarting || isStopping else { return }
        let needsHostStop = receiverLaunchRequested || isRunning || isStopping
        wantsRunning = false
        isStopping = needsHostStop
        isStarting = false
        cancelNetworkPreflight()
        networkSettingsButton.isHidden = true
        clearCode()
        endVideoSession()
        present(.stopped, needsHostStop ? "Stopping the receiver…" : "Wireless receiver stopped.")
        if !needsHostStop {
            if let id = currentRun { statusMailbox.endRun(id) }
            currentRun = nil
        }
        updateControls()
        if needsHostStop { host.stop() }
    }

    func failVideo(_ message: String, id: UUID) {
        guard currentRun == id else { return }
        // Preserve a renderer failure through process shutdown, just as a
        // discovery failure remains visible until the next explicit Start.
        failNetworkPreflight(message)
    }

    func videoDidBecomeReady(id: UUID) {
        guard currentRun == id, wantsRunning, isRunning, !isStopping,
              failureMessage == nil else { return }
        clearCode()
        codeHint.stringValue = "Your iPad is connected. Hide the sidebar or use Clean View before recording."
        present(.authenticated, "Mirroring your iPad in this window.")
    }

    func shutdown(completion: @escaping () -> Void) {
        let needsHostStop = receiverLaunchRequested || isRunning || isStopping
        wantsRunning = false
        isStopping = needsHostStop
        isStarting = false
        cancelNetworkPreflight()
        networkSettingsButton.isHidden = true
        clearCode()
        endVideoSession()
        present(.stopped, needsHostStop ? "Stopping the receiver…" : "Wireless receiver stopped.")
        updateControls()
        if needsHostStop { host.stop { DispatchQueue.main.async { completion() } } }
        else {
            if let id = currentRun { statusMailbox.endRun(id) }
            currentRun = nil
            completion()
        }
    }

    private func beginNetworkPreflight(id: UUID, receiverName: String, resources: URL,
                                      receiveVideo: @escaping @Sendable (UUID, WirelessVideoPacket) -> Bool) {
        cancelNetworkPreflight()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: "local."), using: parameters)
        permissionBrowser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async { [weak self, weak browser] in
                guard let self, let browser, self.permissionBrowser === browser,
                      self.currentRun == id, self.wantsRunning, !self.isStopping else { return }
                switch state {
                case .ready:
                    self.networkSettingsButton.isHidden = true
                    guard !self.receiverLaunchRequested else { return }
                    self.receiverLaunchRequested = true
                    self.present(.starting, "Starting the wireless receiver…")
                    self.updateControls()
                    self.host.start(id: id, receiverName: receiverName, resources: resources,
                                    receiveVideo: { packet in receiveVideo(id, packet) })
                case .waiting(let error):
                    self.clearCode()
                    if case .dns(let code) = error, code == -65570 {
                        if self.receiverLaunchRequested {
                            self.failNetworkPreflight("Local Network access was blocked. Enable iPad to Mac Mirroring in System Settings → Privacy & Security → Local Network, then try again.", showNetworkSettings: true)
                        } else {
                            self.networkSettingsButton.isHidden = false
                            self.present(.starting, "Allow iPad to Mac Mirroring in the Local Network prompt. You can also enable it in Privacy & Security → Local Network.")
                        }
                    } else {
                        self.networkSettingsButton.isHidden = true
                        self.present(.starting, "Waiting for the local network. Connect your Mac and iPad to the same Wi-Fi network, or cancel and try again.")
                    }
                case .failed:
                    self.failNetworkPreflight("Local network discovery could not start. Check Wi-Fi and Local Network access, then try again.")
                case .setup, .cancelled:
                    break
                @unknown default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }

    private func cancelNetworkPreflight() {
        permissionBrowser?.stateUpdateHandler = nil
        permissionBrowser?.cancel()
        permissionBrowser = nil
    }

    private func failNetworkPreflight(_ message: String, showNetworkSettings: Bool = false) {
        let needsHostStop = receiverLaunchRequested || isRunning
        failureMessage = message
        wantsRunning = false
        isStarting = false
        isStopping = needsHostStop
        cancelNetworkPreflight()
        networkSettingsButton.isHidden = !showNetworkSettings
        clearCode()
        endVideoSession()
        present(.failed, message)
        if needsHostStop { host.stop() }
        else {
            if let id = currentRun { statusMailbox.endRun(id) }
            currentRun = nil
            receiverLaunchRequested = false
        }
        updateControls()
    }

    @objc private func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    private func clearCode() {
        codeLabel.stringValue = "— — — —"
        codeHint.stringValue = "Select this receiver in iPad Screen Mirroring. A code appears here when requested."
    }

    private func updateControls() {
        nameField.isEnabled = !wantsRunning && !isRunning && !isStarting && !isStopping
        if isStopping { startButton.title = "Stopping…" }
        else if isStarting && !receiverLaunchRequested { startButton.title = "Cancel" }
        else { startButton.title = (wantsRunning || isRunning || isStarting) ? "Stop Wireless" : "Start Wireless" }
        startButton.isEnabled = !isStopping
    }

    private func receive(id: UUID, event: WirelessEvent) {
        guard currentRun == id else { return }
        switch event {
        case .started:
            // Process existence is factual even if Stop was clicked before
            // this bounded status delivery reached the main thread.
            isRunning = true
            guard wantsRunning else { return }
            present(.starting, "Registering the receiver on the local network…")
        case .bonjourReady:
            guard wantsRunning && !isStopping else { return }
            isStarting = false
            present(.listening, "Select “\(nameField.stringValue)” in iPad Screen Mirroring.")
        case .bonjourFailed(let code):
            let denied = code == -65570 || code == -65571
            let message = denied
                ? "macOS blocked discovery. Enable iPad to Mac Mirroring in Privacy & Security → Local Network, then try again."
                : "Bonjour discovery failed (code \(code)). Check Wi-Fi and try again."
            failNetworkPreflight(message, showNetworkSettings: denied)
        case .challenge(let code):
            guard wantsRunning && !isStopping else { return }
            codeLabel.stringValue = code
            codeHint.stringValue = "Enter this code on the iPad requesting a connection."
            present(.challenge, "Enter the connection code on your iPad.")
        case .authenticated:
            guard wantsRunning && !isStopping else { return }
            clearCode()
            codeHint.stringValue = "Connection approved. Your iPad video will appear in the viewer."
            present(.authenticated, "Connection approved. Waiting for iPad video…")
        case .stopping:
            isStopping = true
            wantsRunning = false
            isStarting = false
            clearCode()
            endVideoSession()
            if failureMessage == nil { present(.stopped, "Stopping the receiver…") }
        case .stopped(let expected, let status):
            cancelNetworkPreflight()
            wantsRunning = false
            isStarting = false
            isRunning = false
            isStopping = false
            currentRun = nil
            statusMailbox.endRun(id)
            receiverLaunchRequested = false
            clearCode()
            endVideoSession()
            if let failureMessage { present(.failed, failureMessage) }
            else if expected { present(.stopped, "Wireless receiver stopped.") }
            else { present(.failed, "The receiver exited (status \(status)). Try again.") }
        case .failed(let message):
            cancelNetworkPreflight()
            // A transport EOF can arrive in a later drain than the concrete
            // policy/decoder failure that caused shutdown. Preserve its useful
            // message and settings action while still completing teardown.
            if failureMessage == nil {
                networkSettingsButton.isHidden = true
                failureMessage = message
            }
            wantsRunning = false
            isStarting = false
            clearCode()
            endVideoSession()
            present(.failed, failureMessage ?? message)
            if !isRunning {
                statusMailbox.endRun(id)
                currentRun = nil
                isStopping = false
                receiverLaunchRequested = false
            }
        }
        updateControls()
    }
}

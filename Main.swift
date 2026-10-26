// Copyright (c) 2026 Russell Varriale (https://github.com/russellvarriale/ipad-to-mac-mirroring)
// SPDX-License-Identifier: MIT
import AppKit
@preconcurrency import AVFoundation
import CoreMediaIO
import CoreMedia

// The USB engine previews only Apple's wired iOS screen source. It never opens a
// camera or microphone, creates a recording, or installs a virtual camera.
struct ScreenSource: Sendable, Equatable {
    let id: String
    let name: String
}

enum PreviewState: Sendable {
    case idle
    case connecting(String)
    case waiting(String)
    case live(String)
    case stalled(String)
    case failed(String)
    case detached
}

enum CaptureEvent: Sendable {
    case sources([ScreenSource])
    case state(PreviewState)
    case dimensions(width: Int32, height: Int32)
    case formatInfo(String)
}

// All capture operations and frame callbacks run on this queue. AppKit and
// the preview layer remain on the main thread.
final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "local.ipadwindow.capture", qos: .userInitiated)
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var devices: [String: AVCaptureDevice] = [:]
    private var activeID: String?
    private var activeName = "iPad"
    private var output: AVCaptureVideoDataOutput?
    private var lastFrame: CFAbsoluteTime?
    private var startedAt: CFAbsoluteTime = 0
    private var hasReportedLive = false
    private var isStalled = false
    private var reportedWidth: Int32 = 0
    private var reportedHeight: Int32 = 0
    private var watchdog: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    var onEvent: (@Sendable (CaptureEvent) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.refresh()
            })
        }
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "The iPad capture session stopped unexpectedly."
            self?.queue.async { [weak self] in
                guard let self, self.activeID != nil else { return }
                self.stopOnQueue()
                self.emit(.state(.failed(message + " Unlock your iPad, close other iPad capture apps, and reconnect.")))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.activeID != nil else { return }
                self.isStalled = true
                self.hasReportedLive = false
                self.emit(.state(.stalled("The iPad stream was interrupted. Keep the iPad unlocked and close other apps using its screen.")))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.activeID != nil else { return }
                self.lastFrame = nil
                self.startedAt = CFAbsoluteTimeGetCurrent()
                self.hasReportedLive = false
                self.isStalled = false
                self.emit(.state(.waiting(self.activeName)))
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        watchdog?.cancel()
    }

    private func emit(_ event: CaptureEvent) { onEvent?(event) }

    private func setCMIOFlag(_ selector: UInt32, value: UInt32) -> OSStatus {
        var address = CMIOObjectPropertyAddress(mSelector: selector,
                                               mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
                                               mElement: UInt32(kCMIOObjectPropertyElementMain))
        var flag = value
        return CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
                                        0, nil, UInt32(MemoryLayout.size(ofValue: flag)), &flag)
    }

    func refresh() {
        queue.async { [weak self] in self?.refreshOnQueue() }
    }

    @discardableResult
    private func refreshOnQueue() -> Bool {
        let result = setCMIOFlag(UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices), value: 1)
        // This is a wired preview app. Do not advertise or open AirPlay sources.
        _ = setCMIOFlag(UInt32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices), value: 0)
        guard result == noErr else {
            stopOnQueue()
            devices.removeAll()
            emit(.sources([]))
            emit(.state(.failed("macOS could not enable wired screen sources (error \(result)). Quit and reopen the app, then reconnect your iPad.")))
            return false
        }
        if discovery == nil {
            discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .continuityCamera],
                                                         mediaType: .muxed, position: .unspecified)
        }
        let found = (discovery?.devices ?? []).filter { device in
            let model = device.modelID.lowercased()
            let isAppleScreen = model.contains("ios device") ||
                (device.manufacturer.lowercased().contains("apple") && device.hasMediaType(.muxed))
            return device.isConnected && device.hasMediaType(.muxed) && isAppleScreen
        }
        devices = Dictionary(uniqueKeysWithValues: found.map { ($0.uniqueID, $0) })
        emit(.sources(found.map { ScreenSource(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }))
        if let activeID, devices[activeID] == nil {
            stopOnQueue()
            emit(.state(.detached))
        }
        return true
    }

    func connect(id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            guard self.refreshOnQueue() else { return }
            guard let device = self.devices[id], device.isConnected else {
                self.emit(.state(.failed("That iPad is no longer available. Reconnect its USB cable, unlock it, and click Refresh.")))
                return
            }
            self.activeID = id
            self.activeName = device.localizedName
            self.emit(.state(.connecting(device.localizedName)))
            do {
                let input = try AVCaptureDeviceInput(device: device)
                // A muxed screen device may also expose an audio stream. This
                // version intentionally enables only video and adds no audio output.
                for port in input.ports where port.mediaType == .audio { port.isEnabled = false }
                self.session.beginConfiguration()
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    throw CaptureFailure("macOS could not attach this iPad screen source.")
                }
                self.session.addInput(input)
                if self.session.canSetSessionPreset(.high) { self.session.sessionPreset = .high }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddOutput(output) else {
                    self.session.commitConfiguration()
                    throw CaptureFailure("macOS could not create the iPad video stream.")
                }
                self.session.addOutput(output)
                self.output = output
                // macOS has no .inputPriority preset. Select the native device
                // format after configuring the outputs, and keep the device lock
                // through commit/start so session negotiation cannot replace it.
                // If locking or format discovery is unavailable, .high remains a
                // working fallback rather than preventing screen preview.
                let holdsDeviceLock = self.configureMaximumVideoFormat(device)
                defer { if holdsDeviceLock { device.unlockForConfiguration() } }
                self.session.commitConfiguration()
                self.startedAt = CFAbsoluteTimeGetCurrent()
                self.lastFrame = nil
                self.hasReportedLive = false
                self.isStalled = false
                self.emit(.state(.waiting(device.localizedName)))
                self.session.startRunning()
                guard self.session.isRunning else {
                    throw CaptureFailure("The iPad screen stream did not start.")
                }
                self.startWatchdog()
            } catch {
                self.stopOnQueue()
                self.emit(.state(.failed(error.localizedDescription + " Unlock and trust your iPad, use a data-capable cable, and close QuickTime or any other app using the iPad screen.")))
            }
        }
    }

    // Returns true with the lock held; the caller releases it after starting.
    // Resolution takes priority, then formats supporting the highest practical
    // frame rate (up to 60 fps). Never substitute still-photo dimensions.
    private func configureMaximumVideoFormat(_ device: AVCaptureDevice) -> Bool {
        let candidates = device.formats.filter { format in
            guard CMFormatDescriptionGetMediaType(format.formatDescription) == kCMMediaType_Video else { return false }
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width > 0 && size.height > 0
        }
        func practicalRate(_ format: AVCaptureDevice.Format) -> Double {
            format.videoSupportedFrameRateRanges
                .filter { $0.minFrameRate <= 60 && $0.maxFrameRate.isFinite && $0.maxFrameRate > 0 }
                .map { min($0.maxFrameRate, 60) }
                .max() ?? 0
        }
        guard let best = candidates.max(by: { first, second in
            let a = CMVideoFormatDescriptionGetDimensions(first.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(second.formatDescription)
            let firstArea = Int64(a.width) * Int64(a.height)
            let secondArea = Int64(b.width) * Int64(b.height)
            return firstArea == secondArea ? practicalRate(first) < practicalRate(second) : firstArea < secondArea
        }) else {
            emit(.formatInfo("This iPad exposes \(device.formats.count) automatic screen stream format(s), with no separately selectable video resolutions. macOS and the iPad negotiate the incoming size."))
            return false
        }
        let bestSize = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        do {
            try device.lockForConfiguration()
        } catch {
            emit(.formatInfo("The highest advertised video format is \(bestSize.width) × \(bestSize.height), but macOS did not allow manual configuration. Using automatic high quality."))
            return false
        }
        guard device.isConnected, device.formats.contains(where: { $0 === best }) else {
            device.unlockForConfiguration()
            return false
        }
        device.activeFormat = best
        emit(.formatInfo("Requested the highest advertised video format: \(bestSize.width) × \(bestSize.height). The incoming size below is measured from actual received frames."))
        // Leave the iPad's frame timing intact; only resolution is overridden.
        return true
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.stopOnQueue()
            self?.emit(.state(.idle))
        }
    }

    private func stopOnQueue() {
        activeID = nil
        watchdog?.cancel()
        watchdog = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for oldOutput in session.outputs { session.removeOutput(oldOutput) }
        for oldInput in session.inputs { session.removeInput(oldInput) }
        session.commitConfiguration()
        output = nil
        lastFrame = nil
        hasReportedLive = false
        isStalled = false
        reportedWidth = 0
        reportedHeight = 0
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.activeID != nil else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - (self.lastFrame ?? self.startedAt)
            // A static iPad screen may legitimately stop sending new frames.
            // Only cover the preview if no first frame ever arrived.
            if elapsed > 12 && self.lastFrame == nil && !self.isStalled {
                self.isStalled = true
                self.hasReportedLive = false
                self.emit(.state(.stalled("No video has arrived for 12 seconds. Unlock the iPad, check the cable and Trust prompt, then disconnect and reconnect if needed.")))
            }
        }
        watchdog = timer
        timer.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard activeID != nil, output === self.output, CMSampleBufferDataIsReady(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = CFAbsoluteTimeGetCurrent()
        let width = Int32(clamping: CVPixelBufferGetWidth(imageBuffer))
        let height = Int32(clamping: CVPixelBufferGetHeight(imageBuffer))
        if width != reportedWidth || height != reportedHeight {
            reportedWidth = width
            reportedHeight = height
            emit(.dimensions(width: width, height: height))
        }
        if !hasReportedLive {
            hasReportedLive = true
            isStalled = false
            emit(.state(.live(activeName)))
        }
    }

    func shutdown(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            self?.stopOnQueue()
            completion()
        }
    }
}

struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class PreviewView: NSView {
    let videoLayer = AVCaptureVideoPreviewLayer()
    let wirelessLayer = AVSampleBufferDisplayLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        wirelessLayer.videoGravity = .resizeAspect
        wirelessLayer.preventsCapture = false
        wirelessLayer.isHidden = true
        layer?.addSublayer(wirelessLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        wirelessLayer.frame = bounds
        CATransaction.commit()
    }
    func attach(_ session: AVCaptureSession) {
        // Establish the preview connection once, before the capture queue starts
        // configuring inputs. Hiding/showing must not mutate session connections.
        if videoLayer.session !== session {
            videoLayer.session = session
            if let connection = videoLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        wirelessLayer.isHidden = true
        videoLayer.isHidden = false
    }
    func showWireless() {
        videoLayer.isHidden = true
        wirelessLayer.isHidden = false
    }
    func clear() {
        videoLayer.isHidden = true
        wirelessLayer.isHidden = true
    }
}

@MainActor
final class ViewerWindow: NSWindow {
    // A borderless preview must still receive the shortcut that restores chrome.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = CaptureEngine()
    private let wirelessController = WirelessReceiverController()
    private enum MirrorMode { case usb, wireless }
    private var mode: MirrorMode = .usb
    private let modePicker = NSSegmentedControl(labels: ["USB", "Wi-Fi"], trackingMode: .selectOne, target: nil, action: nil)
    private let sidebarButton = NSButton(title: "Wireless Setup", target: nil, action: nil)
    private let sidebar = NSView()
    private let body = NSStackView()
    private var usbControls: NSStackView!
    private var chromeHeight: NSLayoutConstraint!
    private var sidebarVisible = false
    private var wirelessSessionID: UUID?
    private var wirelessHasVideo = false
    private var wirelessDisplayAttempt: UUID?
    private lazy var wirelessRenderer = WirelessVideoRenderer(renderer: preview.wirelessLayer.sampleBufferRenderer) { [weak self] id, event in
        self?.receiveWirelessVideo(event, id: id)
    }
    private var window: NSWindow!
    private let preview = PreviewView(frame: .zero)
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Ready")
    private let overlay = NSView()
    private let heading = NSTextField(wrappingLabelWithString: "Your iPad, in a window")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton(title: "Open Camera Privacy Settings", target: nil, action: nil)
    private var chrome = NSView()
    private var footer = NSView()
    private var sources: [ScreenSource] = []
    private var hasLoadedSources = false
    private var incomingPixels: String?
    private var videoSize: NSSize?
    private var changingPresentation = false
    private var sourceFormatInfo = "Connect your iPad to inspect its screen source."
    private var active = false
    private var permissionAttempt: UUID?
    private var hidingControls = false
    private var hideMenuItem: NSMenuItem!
    private var topMenuItem: NSMenuItem!
    private var terminating = false
    private var refreshTimer: Timer?
    private let initialGuidance = "Connect your iPad with a USB data cable. Unlock it and tap Trust if asked.\n\nChoose your iPad above, then click Connect. The first connection asks for Camera permission because macOS treats the iPad screen as a video source."

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        buildWindow()
        preview.attach(engine.session)
        preview.clear()
        configureWireless()
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async { [weak self] in self?.receive(event) }
        }
        showOverlay(title: "Your iPad, in a window", message: initialGuidance)
        engine.refresh()
        // Screen-source publication after enabling CoreMediaIO is asynchronous.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.refresh() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About iPad to Mac Mirroring", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide iPad to Mac Mirroring", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit iPad to Mac Mirroring", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        hideMenuItem = viewMenu.addItem(withTitle: "Hide Controls and Title Bar", action: #selector(toggleControls), keyEquivalent: "h")
        hideMenuItem.keyEquivalentModifierMask = [.command, .shift]
        hideMenuItem.target = self
        topMenuItem = viewMenu.addItem(withTitle: "Always on Top", action: #selector(toggleOnTop), keyEquivalent: "")
        topMenuItem.target = self
        let fit = viewMenu.addItem(withTitle: "Fit Window to iPad", action: #selector(fitWindowToIPad), keyEquivalent: "0")
        fit.target = self
        viewMenu.addItem(.separator())
        let refresh = viewMenu.addItem(withTitle: "Refresh Devices", action: #selector(refreshDevices), keyEquivalent: "r")
        refresh.target = self
        let info = viewMenu.addItem(withTitle: "Stream Information…", action: #selector(showStreamInfo), keyEquivalent: "i")
        info.target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let wireless = windowMenu.addItem(withTitle: "Wireless Sidebar", action: #selector(showWireless), keyEquivalent: "2")
        wireless.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let show = windowMenu.addItem(withTitle: "Show iPad to Mac Mirroring", action: #selector(showWindow), keyEquivalent: "1")
        show.target = self
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let help = helpMenu.addItem(withTitle: "Setup and Recording", action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.mainMenu = main
    }

    private func buildWindow() {
        window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "iPad to Mac Mirroring"
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let previewMenu = NSMenu()
        let restore = previewMenu.addItem(withTitle: "Show Controls and Title Bar", action: #selector(restoreControls), keyEquivalent: "")
        restore.target = self
        preview.menu = previewMenu
        window.setFrameAutosaveName("iPadToMacMirroring.Main")
        window.center()
        let root = NSView()
        window.contentView = root
        chrome = NSView()
        footer = NSView()
        body.orientation = .horizontal
        body.alignment = .centerY
        body.spacing = 0
        body.detachesHiddenViews = true
        body.addArrangedSubview(preview)
        body.addArrangedSubview(sidebar)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        sidebar.isHidden = true
        let stack = NSStackView(views: [chrome, body, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        chromeHeight = chrome.heightAnchor.constraint(equalToConstant: 104)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chrome.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalTo: body.heightAnchor),
            sidebar.heightAnchor.constraint(equalTo: body.heightAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 300),
            preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            chromeHeight,
            footer.heightAnchor.constraint(equalToConstant: 48)
        ])
        modePicker.selectedSegment = 0
        modePicker.target = self
        modePicker.action = #selector(changeMode)
        sidebarButton.target = self
        sidebarButton.action = #selector(toggleSidebar)
        sidebarButton.bezelStyle = .rounded
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [modePicker, status, NSView(), sidebarButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 14
        topRow.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(topRow)
        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 16),
            topRow.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -16),
            topRow.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 12),
            modePicker.widthAnchor.constraint(equalToConstant: 150),
            topRow.heightAnchor.constraint(equalToConstant: 32)
        ])
        let deviceLabel = NSTextField(labelWithString: "USB iPad")
        deviceLabel.font = .systemFont(ofSize: 13, weight: .medium)
        picker.target = self
        picker.action = #selector(pickedDevice)
        picker.addItem(withTitle: "No iPad detected")
        picker.isEnabled = false
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.target = self
        refreshButton.action = #selector(refreshDevices)
        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        usbControls = NSStackView(views: [deviceLabel, picker, refreshButton, connectButton])
        usbControls.orientation = .horizontal
        usbControls.alignment = .centerY
        usbControls.spacing = 10
        usbControls.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(usbControls)
        NSLayoutConstraint.activate([
            usbControls.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 16),
            usbControls.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -16),
            usbControls.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 12),
            picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])
        let footerText = NSTextField(wrappingLabelWithString: "Select this window in your recording app.  •  ⌘⇧H for Clean View  •  Video only")
        footerText.font = .systemFont(ofSize: 12)
        footerText.textColor = .secondaryLabelColor
        footerText.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerText)
        NSLayoutConstraint.activate([
            footerText.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            footerText.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            footerText.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: preview.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: preview.bottomAnchor)
        ])
        let icon = NSImageView(image: NSImage(systemSymbolName: "ipad", accessibilityDescription: "iPad") ?? NSImage())
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        heading.font = .systemFont(ofSize: 27, weight: .semibold)
        heading.textColor = .white
        heading.alignment = .center
        heading.maximumNumberOfLines = 0
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        detail.alignment = .center
        detail.maximumNumberOfLines = 0
        settingsButton.target = self
        settingsButton.action = #selector(openCameraSettings)
        settingsButton.isHidden = true
        let message = NSStackView(views: [icon, heading, detail, settingsButton])
        message.orientation = .vertical
        message.alignment = .centerX
        message.spacing = 20
        message.detachesHiddenViews = true
        message.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 570),
            message.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 36),
            message.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -36),
            detail.widthAnchor.constraint(equalTo: message.widthAnchor),
            heading.widthAnchor.constraint(equalTo: message.widthAnchor),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64)
        ])
    }

    private func configureWireless() {
        let settings = wirelessController.makeView()
        settings.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(settings)
        NSLayoutConstraint.activate([
            settings.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            settings.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            settings.topAnchor.constraint(equalTo: sidebar.topAnchor),
            settings.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
        let renderer = wirelessRenderer
        wirelessController.onVideoPacket = { id, packet in renderer.consume(packet, id: id) }
        wirelessController.onVideoSessionStart = { [weak self] id in
            guard let self else { return }
            self.wirelessSessionID = id
            self.wirelessHasVideo = false
            self.wirelessDisplayAttempt = nil
            renderer.beginSession(id: id)
            if self.mode == .wireless { self.preview.showWireless() }
        }
        wirelessController.onVideoSessionEnd = { [weak self] id in
            renderer.endSession(id: id)
            guard let self, self.wirelessSessionID == id else { return }
            self.wirelessSessionID = nil
            self.wirelessHasVideo = false
            self.wirelessDisplayAttempt = nil
            if self.mode == .wireless {
                self.incomingPixels = nil
                self.videoSize = nil
            }
        }
        wirelessController.onPresentationChange = { [weak self] state in
            self?.updateWirelessPresentation(state)
        }
    }

    private func updateWirelessPresentation(_ state: WirelessPresentationState) {
        guard mode == .wireless, !terminating else { return }
        if wirelessHasVideo && state.phase == .authenticated {
            status.stringValue = "● Live Wi-Fi" + (incomingPixels.map { "  " + $0 } ?? "")
            status.textColor = .systemGreen
            return
        }
        status.textColor = .secondaryLabelColor
        switch state.phase {
        case .stopped:
            status.stringValue = "Wi-Fi stopped"
            showOverlay(title: "Mirror over Wi-Fi", message: "Start the receiver in the sidebar, then select iPad to Mac Mirroring in your iPad’s Screen Mirroring menu.\n\nBoth devices must be on the same trusted network.")
        case .starting:
            status.stringValue = "Starting Wi-Fi…"
            showOverlay(title: "Starting wireless receiver", message: state.message)
        case .listening:
            status.stringValue = "Ready for iPad"
            showOverlay(title: "Connect your iPad", message: "Open Control Center → Screen Mirroring on your iPad and choose the receiver name in the sidebar.\n\nThe iPad screen will appear here.")
        case .challenge:
            status.stringValue = "Enter connection code"
            showOverlay(title: "Pair your iPad", message: "Enter the code shown in the sidebar on your iPad.\n\nIf controls are hidden, press ⌘⇧H to show them.")
        case .authenticated:
            status.stringValue = "Waiting for video…"
            showOverlay(title: "Waiting for wireless video", message: "Your iPad is connected. Its screen will appear here when the first frame arrives.")
        case .failed:
            status.stringValue = "Wireless connection issue"
            status.textColor = .systemOrange
            showOverlay(title: "Couldn’t show wireless video", message: state.message)
        }
    }

    private func receiveWirelessVideo(_ event: WirelessVideoEvent, id: UUID) {
        guard mode == .wireless, wirelessSessionID == id, !terminating else { return }
        switch event {
        case .dimensions(let width, let height):
            let previous = videoSize
            window.contentView?.layoutSubtreeIfNeeded()
            var preferred = preview.bounds.size
            if let previous, (previous.width > previous.height) != (width > height) {
                preferred = NSSize(width: preferred.height, height: preferred.width)
            }
            videoSize = NSSize(width: CGFloat(width), height: CGFloat(height))
            incomingPixels = "\(width) × \(height)"
            fitWindowToVideo(preferredSize: preferred)
            if wirelessHasVideo {
                status.stringValue = "● Live Wi-Fi  \(incomingPixels!)"
            }
        case .live:
            let attempt = UUID()
            wirelessDisplayAttempt = attempt
            showWirelessWhenReady(id: id, attempt: attempt,
                                  deadline: ProcessInfo.processInfo.systemUptime + 3)
        case .reset:
            wirelessDisplayAttempt = nil
            wirelessHasVideo = false
            incomingPixels = nil
            status.stringValue = "Waiting for video…"
            status.textColor = .secondaryLabelColor
            showOverlay(title: "Waiting for your iPad", message: "The receiver is running. Reconnect through Screen Mirroring if your iPad disconnected.")
        case .failed(let message):
            wirelessController.failVideo(message, id: id)
            status.stringValue = "Wireless video issue"
            status.textColor = .systemOrange
            showOverlay(title: "Couldn’t display wireless video", message: message)
        }
    }

    private func showWirelessWhenReady(id: UUID, attempt: UUID, deadline: TimeInterval) {
        guard mode == .wireless, wirelessSessionID == id,
              wirelessDisplayAttempt == attempt, !terminating else { return }
        let ready: Bool
        if #available(macOS 14.4, *) { ready = preview.wirelessLayer.isReadyForDisplay }
        else { ready = preview.wirelessLayer.sampleBufferRenderer.status == .rendering }
        if ready {
            wirelessDisplayAttempt = nil
            wirelessHasVideo = true
            preview.showWireless()
            status.stringValue = "● Live Wi-Fi" + (incomingPixels.map { "  " + $0 } ?? "")
            status.textColor = .systemGreen
            window.subtitle = "Wi-Fi"
            overlay.isHidden = true
            wirelessController.videoDidBecomeReady(id: id)
        } else if ProcessInfo.processInfo.systemUptime < deadline {
            // Only one short readiness check is pending for this display attempt.
            // Frame data stays on the transport queue; no frames enter this queue.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.showWirelessWhenReady(id: id, attempt: attempt, deadline: deadline)
            }
        } else {
            wirelessDisplayAttempt = nil
            wirelessController.failVideo("macOS could not display the wireless video. Stop and reconnect your iPad.", id: id)
        }
    }

    private func showOverlay(title: String, message: String, settings: Bool = false) {
        heading.stringValue = title
        detail.stringValue = message
        settingsButton.isHidden = !settings
        overlay.isHidden = false
    }

    private func setActive(_ value: Bool) {
        active = value
        picker.isEnabled = !value && !sources.isEmpty
        if value { connectButton.title = "Disconnect" }
        else if sources.isEmpty {
            connectButton.title = AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? "Check for iPad" : "Enable iPad Access"
        } else { connectButton.title = "Connect" }
        connectButton.isEnabled = true
    }

    private func receive(_ event: CaptureEvent) {
        guard !terminating else { return }
        switch event {
        case .formatInfo(let info):
            if mode == .usb { sourceFormatInfo = info }
        case .dimensions(let width, let height):
            guard mode == .usb else { return }
            let previous = videoSize
            window.contentView?.layoutSubtreeIfNeeded()
            var preferred = preview.bounds.size
            if let previous, (previous.width > previous.height) != (width > height) {
                preferred = NSSize(width: preferred.height, height: preferred.width)
            }
            videoSize = NSSize(width: CGFloat(width), height: CGFloat(height))
            incomingPixels = "\(width) × \(height)"
            fitWindowToVideo(preferredSize: preferred)
            if status.stringValue.hasPrefix("● Live") {
                status.stringValue = "● Live  \(incomingPixels!)"
            }
        case .sources(let found):
            if hasLoadedSources && sources == found { return }
            hasLoadedSources = true
            let previous = picker.selectedItem?.representedObject as? String
            sources = found
            picker.removeAllItems()
            if found.isEmpty {
                picker.addItem(withTitle: "No iPad detected")
            } else {
                for source in found {
                    picker.addItem(withTitle: source.name)
                    picker.lastItem?.representedObject = source.id
                }
                if let previous, let item = picker.itemArray.first(where: { ($0.representedObject as? String) == previous }) { picker.select(item) }
            }
            setActive(active)
            if mode == .usb && !active && permissionAttempt == nil && !found.isEmpty && status.stringValue == "Ready" {
                showOverlay(title: "\(found.first!.name) is ready", message: "Click Connect to show the iPad screen here.\n\nIn your recorder, select this window and enable your Mac camera for picture in picture.")
            }
        case .state(let state):
            guard mode == .usb else { return }
            switch state {
            case .idle:
                incomingPixels = nil
                videoSize = nil
                setActive(false)
                preview.clear()
                status.stringValue = "Ready"
                status.textColor = .secondaryLabelColor
                showOverlay(title: "Your iPad, in a window", message: initialGuidance)
            case .connecting(let name):
                incomingPixels = nil
                videoSize = nil
                setActive(true)
                preview.attach(engine.session)
                status.stringValue = "Connecting…"
                status.textColor = .secondaryLabelColor
                showOverlay(title: "Connecting to \(name)", message: "Keep your iPad unlocked. The preview will appear when the first video frame arrives.")
            case .waiting(let name):
                setActive(true)
                preview.attach(engine.session)
                status.stringValue = "Waiting for video…"
                showOverlay(title: "Waiting for \(name)", message: "Unlock your iPad and accept Trust if prompted.\n\nIf this continues, check that your USB cable supports data and close other iPad capture apps.")
            case .live(let name):
                setActive(true)
                status.stringValue = "● Live" + (incomingPixels.map { "  " + $0 } ?? "")
                status.textColor = .systemGreen
                window.title = "iPad to Mac Mirroring"
                window.subtitle = name
                overlay.isHidden = true
            case .stalled(let message):
                status.stringValue = "Video paused"
                status.textColor = .systemOrange
                showOverlay(title: "Waiting for video", message: message)
            case .failed(let message):
                videoSize = nil
                permissionAttempt = nil
                setActive(false)
                preview.clear()
                status.stringValue = "Connection issue"
                status.textColor = .systemOrange
                showOverlay(title: "Couldn’t show the iPad", message: message)
            case .detached:
                videoSize = nil
                permissionAttempt = nil
                setActive(false)
                preview.clear()
                status.stringValue = "Disconnected"
                status.textColor = .secondaryLabelColor
                window.subtitle = ""
                showOverlay(title: "iPad disconnected", message: "Reconnect the USB data cable and unlock your iPad.\n\nSelect it above and click Connect to resume.")
            }
        }
    }

    @objc private func toggleConnection() {
        guard mode == .usb else { return }
        if active {
            permissionAttempt = nil
            preview.clear()
            setActive(false)
            engine.disconnect()
            return
        }
        let id = picker.selectedItem?.representedObject as? String
        let attempt = UUID()
        permissionAttempt = attempt
        setActive(true)
        status.stringValue = "Checking permission…"
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionAttempt = nil
            if let id { engine.connect(id: id) }
            else {
                setActive(false)
                status.stringValue = "Ready"
                showOverlay(title: "Looking for your iPad", message: initialGuidance + "\n\nIf the device remains missing, try reconnecting the cable or another USB port.")
                engine.refresh()
            }
        case .notDetermined:
            showOverlay(title: "Allow the iPad screen source", message: "macOS calls this Camera permission. iPad to Mac Mirroring uses it only to display your connected iPad screen.\n\nClick Allow in the permission prompt to continue.")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.mode == .usb, self.permissionAttempt == attempt, !self.terminating else { return }
                    self.permissionAttempt = nil
                    if granted {
                        if let id { self.engine.connect(id: id) }
                        else {
                            self.setActive(false)
                            self.status.stringValue = "Ready"
                            self.showOverlay(title: "Access enabled", message: self.initialGuidance)
                            self.engine.refresh()
                        }
                    }
                    else { self.permissionDenied() }
                }
            }
        case .denied, .restricted:
            permissionAttempt = nil
            permissionDenied()
        @unknown default:
            permissionAttempt = nil
            permissionDenied()
        }
    }

    private func permissionDenied() {
        setActive(false)
        preview.clear()
        status.stringValue = "Permission needed"
        status.textColor = .systemOrange
        showOverlay(title: "Allow Camera access to continue", message: "Open System Settings → Privacy & Security → Camera and enable iPad to Mac Mirroring. Then return and click Connect.\n\nIf macOS asks you to quit the app after changing access, quit and reopen it.", settings: true)
    }

    @objc private func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
    }
    @objc private func pickedDevice() { /* Selection is opened only by Connect. */ }
    @objc private func refreshDevices() { engine.refresh() }
    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        engine.refresh()
    }
    @objc private func showWireless() {
        if hidingControls { toggleControls() }
        selectMode(.wireless)
        setSidebarVisible(true)
        showWindow()
    }

    @objc private func changeMode() { selectMode(modePicker.selectedSegment == 0 ? .usb : .wireless) }

    private func selectMode(_ selected: MirrorMode) {
        guard selected != mode else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let preferred = preview.bounds.size
        permissionAttempt = nil
        if selected == .wireless {
            setActive(false)
            engine.disconnect()
        } else {
            wirelessController.stop()
            wirelessRenderer.endSession()
            wirelessSessionID = nil
            wirelessHasVideo = false
            wirelessDisplayAttempt = nil
        }
        mode = selected
        modePicker.selectedSegment = selected == .usb ? 0 : 1
        usbControls.isHidden = selected != .usb
        chromeHeight.constant = selected == .usb ? 104 : 56
        incomingPixels = nil
        videoSize = nil
        window.subtitle = ""
        preview.clear()
        if selected == .wireless {
            sourceFormatInfo = "Wireless requests 1920 × 1440 at up to 60 fps. The incoming resolution is measured from the negotiated H.264 video."
            preview.showWireless()
            setSidebarVisible(true, fit: false)
            updateWirelessPresentation(wirelessController.presentationState)
        } else {
            sourceFormatInfo = "Connect your iPad to inspect its screen source."
            setSidebarVisible(false, fit: false)
            status.stringValue = "Ready"
            status.textColor = .secondaryLabelColor
            showOverlay(title: "Your iPad, in a window", message: initialGuidance)
            engine.refresh()
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if videoSize != nil { fitWindowToVideo(preferredSize: preferred) }
    }

    @objc private func toggleSidebar() {
        if mode != .wireless { showWireless(); return }
        setSidebarVisible(!sidebarVisible)
    }

    private func setSidebarVisible(_ visible: Bool, fit: Bool = true) {
        window.contentView?.layoutSubtreeIfNeeded()
        let preferred = preview.bounds.size
        sidebarVisible = visible
        sidebar.isHidden = !visible || hidingControls
        sidebarButton.title = visible ? "Hide Sidebar" : "Wireless Setup"
        if fit { fitWindowToVideo(preferredSize: preferred) }
    }
    @objc private func toggleControls() {
        window.contentView?.layoutSubtreeIfNeeded()
        let videoBounds = preview.bounds.size
        changingPresentation = true
        hidingControls.toggle()
        chrome.isHidden = hidingControls
        footer.isHidden = hidingControls
        sidebar.isHidden = hidingControls || !sidebarVisible
        let frame = window.frame
        if hidingControls {
            window.styleMask.remove(.titled)
            window.backgroundColor = .black
        } else {
            window.styleMask.insert(.titled)
            window.backgroundColor = .windowBackgroundColor
        }
        window.isMovableByWindowBackground = hidingControls
        window.setFrame(frame, display: true)
        changingPresentation = false
        fitWindowToVideo(preferredSize: videoBounds)
        window.makeKeyAndOrderFront(nil)
        hideMenuItem.title = hidingControls ? "Show Controls and Title Bar" : "Hide Controls and Title Bar"
        hideMenuItem.state = hidingControls ? .on : .off
    }
    @objc private func restoreControls() {
        if hidingControls { toggleControls() }
    }
    private var controlsHeight: CGFloat { hidingControls ? 0 : (mode == .usb ? 152 : 104) }
    private var sidebarWidth: CGFloat { !hidingControls && sidebarVisible ? 300 : 0 }

    @objc private func fitWindowToIPad() {
        window.contentView?.layoutSubtreeIfNeeded()
        fitWindowToVideo(preferredSize: preview.bounds.size)
    }

    private func fitWindowToVideo(preferredSize: NSSize) {
        guard !changingPresentation, !window.styleMask.contains(.fullScreen),
              let videoSize, videoSize.width > 0, videoSize.height > 0 else { return }
        let ratio = videoSize.width / videoSize.height
        let available = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let maxContent = window.contentRect(forFrameRect: available).size
        let maxWidth = min(maxContent.width - sidebarWidth, max(1, maxContent.height - controlsHeight) * ratio)
        let proposedWidth = min(max(1, preferredSize.width), max(1, preferredSize.height) * ratio)
        let minimumWidth = min(hidingControls ? 280 : max(280, 640 - sidebarWidth), maxWidth)
        let width = min(maxWidth, max(minimumWidth, proposedWidth))
        let content = NSRect(x: 0, y: 0, width: width + sidebarWidth, height: width / ratio + controlsHeight)
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !changingPresentation, !sender.styleMask.contains(.fullScreen),
              let videoSize, videoSize.width > 0, videoSize.height > 0 else { return frameSize }
        let ratio = videoSize.width / videoSize.height
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let current = sender.contentRect(forFrameRect: sender.frame).size
        let widthDriven = abs(proposed.width - current.width) >= abs(proposed.height - current.height) * ratio
        let visible = (sender.screen ?? NSScreen.main)?.visibleFrame ?? sender.frame
        let availableContent = sender.contentRect(forFrameRect: visible).size
        let compatibleWidth = min(availableContent.width - sidebarWidth, max(1, availableContent.height - controlsHeight) * ratio)
        let minimumWidth: CGFloat = min(hidingControls ? 280 : max(280, 640 - sidebarWidth), compatibleWidth)
        let width = max(minimumWidth, widthDriven ? proposed.width - sidebarWidth : max(180, proposed.height - controlsHeight) * ratio)
        return sender.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width + sidebarWidth, height: width / ratio + controlsHeight)).size
    }

    func windowWillEnterFullScreen(_ notification: Notification) { changingPresentation = true }
    func windowDidEnterFullScreen(_ notification: Notification) { changingPresentation = false }
    func windowWillExitFullScreen(_ notification: Notification) { changingPresentation = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        changingPresentation = false
        fitWindowToIPad()
    }
    @objc private func showStreamInfo() {
        let alert = NSAlert()
        alert.messageText = "Incoming resolution: \(incomingPixels ?? "not connected")"
        alert.informativeText = sourceFormatInfo + "\n\nA larger window scales these pixels; it cannot add source detail. Keep the viewer near the incoming pixel size and choose a suitable quality in your recording app."
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }
    @objc private func toggleOnTop() {
        let onTop = window.level == .normal
        window.level = onTop ? .floating : .normal
        topMenuItem.state = onTop ? .on : .off
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "iPad to Mac Mirroring", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2.0", .credits: NSAttributedString(string: "Created by Russell Varriale\nhttps://github.com/russellvarriale/ipad-to-mac-mirroring\n\nUSB and wireless iPad mirroring for Mac recording apps.\nWireless receiver powered by UxPlay and GStreamer.\nOriginal app code: MIT. Wireless receiver: GPL-3.0-or-later.\nSee included licenses and third-party notices.")])
    }
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Record your iPad"
        alert.informativeText = "1. Connect the iPad to your Mac using a USB cable that supports data. Unlock it and tap Trust if asked.\n\n2. Select your iPad and click Connect. Allow Camera access when macOS asks. This app uses only the iPad screen source.\n\n3. Resize this window. In your recording app, select this window and enable your Mac camera for picture in picture. Select your microphone there too.\n\n4. Press ⌘⇧H to hide or show the controls and title bar. Drag the clean window by its image; resize at the edges or right-click to restore its controls. Choose View → Always on Top if helpful.\n\nThe control bar shows the actual incoming resolution. The app requests the highest resolution the iPad exposes over USB; enlarging the window beyond that will not add detail. The iPad stays controlled by touch. For Wi-Fi mirroring, select Wi-Fi at the top and start the receiver in its sidebar (⌘2). Wireless video appears in this same window. Hide its sidebar or use Clean View before recording. Both modes are video only; use your recording app for your camera and microphone. If nothing appears, close QuickTime or other apps using the iPad screen, then disconnect and reconnect."
        alert.addButton(withTitle: "Got It")
        alert.runModal()
    }

    func windowWillClose(_ notification: Notification) {
        permissionAttempt = nil
        preview.clear()
        setActive(false)
        engine.disconnect()
        wirelessController.stop()
        wirelessRenderer.endSession()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        permissionAttempt = nil
        refreshTimer?.invalidate()
        preview.clear()
        let finish = {
            self.engine.shutdown {
                DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        wirelessController.shutdown(completion: finish)
        return .terminateLater
    }
}

@main
enum IPadWindowApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

// Synthetic video only: no camera, screen, network, or receiver is opened.
// A temporary borderless window lets CoreMedia actually decode the generated
// H.264 samples; the harness closes it before returning.
import Foundation
import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

private struct RendererTestFailure: Error { let message: String }

private final class EncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [Data] = []
    private var encounteredFailure = false
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return captured }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return encounteredFailure }
    func fail() { lock.lock(); encounteredFailure = true; lock.unlock() }
    func accept(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { encounteredFailure = true; return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        var packet = Data()
        // Real streams commonly supply codec parameters on the IDR only. The
        // dependent frames therefore exercise the production codec-state cache.
        if isSync {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer, length > 0 else { encounteredFailure = true; return }
                packet.append(contentsOf: [0, 0, 0, 1]); packet.append(pointer, count: length)
            }
        }
        let size = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: size)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: &bytes) == noErr else {
            encounteredFailure = true; return
        }
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 |
                Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, length <= bytes.count - offset else { encounteredFailure = true; return }
            packet.append(contentsOf: [0, 0, 0, 1])
            packet.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        }
        guard offset == bytes.count else { encounteredFailure = true; return }
        captured.append(packet)
    }
}

@MainActor private final class RenderEvents {
    var values: [(UUID, WirelessVideoEvent)] = []
    func clear() { values.removeAll(keepingCapacity: true) }
    var liveCount: Int { values.filter { if case .live = $0.1 { return true }; return false }.count }
    var failureCount: Int { values.filter { if case .failed = $0.1 { return true }; return false }.count }
    var resetCount: Int { values.filter { if case .reset = $0.1 { return true }; return false }.count }
}

@main private enum WirelessVideoRendererTests {
    @MainActor static func main() {
        do { try run() }
        catch let failure as RendererTestFailure { print("FAIL: " + failure.message); exit(1) }
        catch { print("FAIL: synthetic renderer test could not complete"); exit(1) }
    }

    @MainActor private static func run() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw RendererTestFailure(message: message) }
            checks += 1
        }
        func drainRunLoop(_ duration: TimeInterval = 0.04) {
            let deadline = Date(timeIntervalSinceNow: duration)
            while Date() < deadline { RunLoop.current.run(until: min(deadline, Date(timeIntervalSinceNow: 0.005))) }
        }
        func annex(_ nals: [Data]) -> Data {
            var result = Data()
            for nal in nals { result.append(contentsOf: [0, 0, 0, 1]); result.append(nal) }
            return result
        }

        for data in [Data(), Data([1, 2, 3]), Data([0, 0, 0, 1]), Data([0, 0, 0, 1, 0x80]),
                     Data([0, 0, 0, 1, 0x18]), Data([0, 0, 1, 0x00])] {
            try check(WirelessH264AccessUnit.parse(data) == nil, "malformed Annex-B input was accepted")
        }
        let simpleIDR = Data([0, 0, 1, 0x65, 0x88])
        let simple = WirelessH264AccessUnit.parse(simpleIDR)
        try check(simple?.isKeyframe == true && simple?.containsPicture == true,
                  "three-byte start code did not identify an IDR")
        try check(simple?.avcc == Data([0, 0, 0, 2, 0x65, 0x88]), "Annex-B to AVCC length conversion failed")
        try check(WirelessH264AccessUnit.parse(simpleIDR + Data([0, 0, 0]))?.avcc == simple?.avcc,
                  "Annex-B trailing zeros entered the NAL payload")
        try check(WirelessH264AccessUnit.parse(Data(repeating: 1, count: 16 * 1024 * 1024 + 1)) == nil,
                  "oversized access unit passed its input bound")
        let exactParameter = Data([0x67]) + Data(repeating: 0x11, count: 64 * 1024 - 1)
        try check(WirelessH264AccessUnit.parse(annex([exactParameter]))?.sequence?.count == 64 * 1024,
                  "parameter-set boundary was rejected")
        try check(WirelessH264AccessUnit.parse(annex([exactParameter + Data([0x11])])) == nil,
                  "oversized parameter set passed its bound")
        try check(WirelessH264AccessUnit.parse(annex(Array(repeating: Data([0x06, 0x80]), count: 256))) != nil,
                  "NAL-count boundary was rejected")
        try check(WirelessH264AccessUnit.parse(annex(Array(repeating: Data([0x06, 0x80]), count: 257))) == nil,
                  "excessive NAL count passed its bound")

        let encoded = EncodedFrames()
        var compression: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { pointer, _, status, _, sample in
            guard let pointer else { return }
            let encoded = Unmanaged<EncodedFrames>.fromOpaque(pointer).takeUnretainedValue()
            if status == noErr, let sample { encoded.accept(sample) } else { encoded.fail() }
        }
        try check(VTCompressionSessionCreate(allocator: nil, width: 384, height: 256,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: callback,
            refcon: Unmanaged.passUnretained(encoded).toOpaque(), compressionSessionOut: &compression) == noErr,
            "synthetic H.264 encoder could not start")
        guard let compression else { throw RendererTestFailure(message: "synthetic encoder was unavailable") }
        defer { VTCompressionSessionInvalidate(compression) }
        for (key, value) in [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
                             (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
                             (kVTCompressionPropertyKey_MaxKeyFrameInterval, 60 as CFNumber)] {
            try check(VTSessionSetProperty(compression, key: key, value: value) == noErr,
                      "synthetic encoder property was unsupported")
        }
        var images: [CVPixelBuffer] = []
        for index in 0..<3 {
            var image: CVPixelBuffer?
            try check(CVPixelBufferCreate(kCFAllocatorDefault, 384, 256, kCVPixelFormatType_32BGRA,
                                         nil, &image) == kCVReturnSuccess, "synthetic pixel buffer was unavailable")
            guard let image else { throw RendererTestFailure(message: "synthetic pixel buffer was missing") }
            CVPixelBufferLockBaseAddress(image, [])
            if let base = CVPixelBufferGetBaseAddress(image) {
                memset(base, 127, CVPixelBufferGetDataSize(image))
                // A tiny change retains real reference-frame dependencies without
                // triggering the encoder's scene-change keyframe heuristic.
                memset(base, Int32(140 + index), 128)
            }
            CVPixelBufferUnlockBaseAddress(image, [])
            images.append(image)
            let properties: CFDictionary? = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            try check(VTCompressionSessionEncodeFrame(compression, imageBuffer: image,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 60),
                duration: CMTime(value: 1, timescale: 60), frameProperties: properties,
                sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr, "synthetic frame encode failed")
        }
        try check(VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid) == noErr,
                  "synthetic encoder did not finish")
        let frames = encoded.frames
        try check(!encoded.failed && frames.count == 3, "synthetic encoder did not produce three frames")
        let parsed = frames.compactMap(WirelessH264AccessUnit.parse)
        try check(parsed.count == 3 && parsed.map(\.isKeyframe) == [true, false, false],
                  "synthetic sequence did not contain an IDR followed by two dependent frames")
        try check(parsed[0].sequence != nil && parsed[0].picture != nil &&
                  parsed[1].sequence == nil && parsed[1].picture == nil,
                  "dependent frames did not exercise cached codec parameters")

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 384, height: 256),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Synthetic Video Decoder Test"
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = NSRect(x: 0, y: 0, width: 384, height: 256)
        window.contentView?.layer?.addSublayer(layer)
        window.orderFront(nil)
        defer { window.close() }
        let events = RenderEvents()
        let renderer = WirelessVideoRenderer(renderer: layer.sampleBufferRenderer) { id, event in
            events.values.append((id, event))
        }
        let first = UUID()
        renderer.beginSession(id: first)
        for frame in frames { try check(renderer.consume(.accessUnit(frame), id: first), "production renderer rejected encoded frame") }
        let readyDeadline = Date(timeIntervalSinceNow: 2)
        while Date() < readyDeadline && !layer.isReadyForDisplay { drainRunLoop(0.01) }
        drainRunLoop()
        try check(layer.sampleBufferRenderer.status != .failed && layer.isReadyForDisplay,
                  "CoreMedia did not decode the generated reference-frame chain")
        try check(events.values.count == 2 && events.values.allSatisfy { $0.0 == first },
                  "initial dimensions and live events were not bounded to the active run")
        try check({ if case .dimensions(384, 256) = events.values[0].1,
                       case .live = events.values[1].1 { return true }; return false }(),
                  "dimensions were not delivered before the live event")

        events.clear()
        try check(renderer.consume(.accessUnit(Data([9])), id: UUID()), "stale malformed frame was not ignored")
        try check(renderer.consume(.reset, id: UUID()), "stale reset was not ignored")
        drainRunLoop()
        try check(events.values.isEmpty, "stale packets emitted UI state")
        renderer.endSession(id: UUID())
        try check(renderer.consume(.reset, id: first), "active reset was rejected")
        drainRunLoop()
        try check(events.resetCount == 1, "wrong-session end terminated the active run")

        events.clear()
        let metadata = annex([parsed[0].sequence!, parsed[0].picture!])
        try check(renderer.consume(.accessUnit(metadata), id: first), "codec-parameter-only packet was rejected")
        try check(renderer.consume(.accessUnit(frames[1]), id: first), "dependent frame before recovery IDR was rejected")
        drainRunLoop()
        try check(events.liveCount == 0 && events.failureCount == 0,
                  "dependent frame resumed video before the required recovery IDR")
        events.clear()
        try check(renderer.consume(.accessUnit(frames[0]), id: first), "recovery IDR was rejected")
        drainRunLoop()
        try check(events.liveCount == 1, "recovery IDR did not resume video")

        events.clear()
        for _ in 0..<512 { _ = renderer.consume(.reset, id: first) }
        try check(events.values.isEmpty, "renderer UI events were delivered synchronously while main was busy")
        drainRunLoop()
        try check(events.values.count == 1 && events.resetCount == 1, "reset flood was not coalesced to its latest state")

        events.clear()
        _ = renderer.consume(.reset, id: first)
        let second = UUID()
        renderer.beginSession(id: second)
        drainRunLoop()
        try check(events.values.isEmpty, "new session delivered a pending old-run event")
        _ = renderer.consume(.reset, id: second)
        renderer.endSession(id: second)
        drainRunLoop()
        try check(events.values.isEmpty, "ended session delivered a pending event")
        try check(renderer.consume(.accessUnit(Data([9])), id: second), "ended run did not ignore malformed packets")

        let third = UUID()
        renderer.beginSession(id: third)
        try check(!renderer.consume(.accessUnit(Data([9])), id: third), "active malformed packet did not fail closed")
        let fourth = UUID()
        renderer.beginSession(id: fourth)
        _ = renderer.consume(.reset, id: fourth)
        drainRunLoop()
        try check(events.values.count == 1 && events.values[0].0 == fourth && events.resetCount == 1,
                  "stale scheduled drain lost the replacement run or emitted the old failure")
        events.clear()
        let invalidParameters = annex([Data([0x67]), Data([0x68])])
        try check(!renderer.consume(.accessUnit(invalidParameters), id: fourth),
                  "invalid H.264 codec parameters did not fail closed")
        drainRunLoop()
        try check(events.failureCount == 1 && events.liveCount == 0, "invalid codec parameters did not report a bounded failure")
        renderer.endSession(id: fourth)
        print("PASS: \(checks) synthetic H.264 parser, decoder, and session checks")
        withExtendedLifetime(images) {}
    }
}

// Copyright (c) 2026 Russell Varriale (https://github.com/russellvarriale/ipad-to-mac-mirroring)
// SPDX-License-Identifier: MIT
import Foundation
@preconcurrency import AVFoundation
import CoreMedia

// Wireless video is delivered through an inherited socket, never a recording
// file or a screen capture. Only bounded H.264 access units reach CoreMedia.
enum WirelessVideoEvent: Sendable {
    case dimensions(Int32, Int32)
    case live
    case reset
    case failed(String)
}

struct WirelessH264AccessUnit {
    let sequence: Data?
    let picture: Data?
    let avcc: Data
    let isKeyframe: Bool
    let containsPicture: Bool

    static func parse(_ data: Data) -> WirelessH264AccessUnit? {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { return nil }
        return data.withUnsafeBytes { raw -> WirelessH264AccessUnit? in
            let bytes = raw.bindMemory(to: UInt8.self)
            func prefixLength(_ index: Int) -> Int {
                if index + 3 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0,
                   bytes[index + 2] == 0, bytes[index + 3] == 1 { return 4 }
                if index + 2 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0,
                   bytes[index + 2] == 1 { return 3 }
                return 0
            }
            guard prefixLength(0) > 0 else { return nil }
            var cursor = 0
            var count = 0
            var sequence: Data?
            var picture: Data?
            var avcc = Data()
            avcc.reserveCapacity(data.count)
            var keyframe = false
            var containsPicture = false
            while cursor < bytes.count {
                let prefix = prefixLength(cursor)
                guard prefix > 0 else { return nil }
                let start = cursor + prefix
                var end = start
                while end < bytes.count, prefixLength(end) == 0 { end += 1 }
                // Annex-B trailing_zero_8bits are outside the NAL unit.
                var nalEnd = end
                while nalEnd > start, bytes[nalEnd - 1] == 0 { nalEnd -= 1 }
                guard nalEnd > start, bytes[start] & 0x80 == 0 else { return nil }
                count += 1
                guard count <= 256 else { return nil }
                let type = bytes[start] & 0x1f
                guard type > 0, type < 24 else { return nil }
                let length = nalEnd - start
                if type == 7 || type == 8 {
                    guard length <= 64 * 1024 else { return nil }
                    let parameter = Data(bytes[start..<nalEnd])
                    if type == 7 { sequence = parameter } else { picture = parameter }
                } else {
                    var size = UInt32(length).bigEndian
                    withUnsafeBytes(of: &size) { avcc.append(contentsOf: $0) }
                    avcc.append(contentsOf: bytes[start..<nalEnd])
                    if type == 5 { keyframe = true }
                    if (1...5).contains(type) { containsPicture = true }
                }
                cursor = end
            }
            return WirelessH264AccessUnit(sequence: sequence, picture: picture, avcc: avcc,
                                          isKeyframe: keyframe, containsPicture: containsPicture)
        }
    }
}

// The renderer and codec state are serialized by this lock. The transport calls
// consume synchronously on its video queue: it cannot enqueue an unbounded run
// of frame closures onto the main queue. UI callbacks carry the session ID.
final class WirelessVideoRenderer: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var sessionID: UUID?
    private var sequence: Data?
    private var picture: Data?
    private var format: CMVideoFormatDescription?
    private var requiresKeyframe = true
    private var reportedLive = false
    private var frameNumber: Int64 = 0
    private let onEvent: @MainActor @Sendable (UUID, WirelessVideoEvent) -> Void
    private var pendingSession: UUID?
    private var pendingDimensions: (Int32, Int32)?
    private var pendingState: WirelessVideoEvent?
    private var deliveryScheduled = false

    init(renderer: AVSampleBufferVideoRenderer,
         onEvent: @escaping @MainActor @Sendable (UUID, WirelessVideoEvent) -> Void) {
        self.renderer = renderer
        self.onEvent = onEvent
    }

    func beginSession(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        sessionID = id
        clearPendingEvents()
        resetCodec(removeImage: true)
    }

    func endSession(id: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard id == nil || sessionID == id else { return }
        sessionID = nil
        clearPendingEvents()
        resetCodec(removeImage: true)
    }

    private func clearPendingEvents() {
        pendingSession = nil
        pendingDimensions = nil
        pendingState = nil
        // A previously queued drain still owns deliveryScheduled until it runs.
    }

    private func emit(_ id: UUID, _ event: WirelessVideoEvent) {
        if pendingSession != id {
            pendingSession = id
            pendingDimensions = nil
            pendingState = nil
        }
        switch event {
        case .dimensions(let width, let height): pendingDimensions = (width, height)
        case .reset:
            pendingDimensions = nil
            pendingState = .reset
        case .live, .failed: pendingState = event
        }
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        DispatchQueue.main.async { [weak self] in self?.deliverEvents() }
    }

    @MainActor private func deliverEvents() {
        lock.lock()
        let id = pendingSession
        let dimensions = pendingDimensions
        let state = pendingState
        let current = sessionID
        pendingSession = nil
        pendingDimensions = nil
        pendingState = nil
        deliveryScheduled = false
        lock.unlock()
        guard let id, id == current else { return }
        if let dimensions { onEvent(id, .dimensions(dimensions.0, dimensions.1)) }
        if let state { onEvent(id, state) }
    }

    private func resetCodec(removeImage: Bool) {
        sequence = nil
        picture = nil
        format = nil
        requiresKeyframe = true
        reportedLive = false
        frameNumber = 0
        renderer.flush(removingDisplayedImage: removeImage, completionHandler: nil)
    }

    @discardableResult
    func consume(_ packet: WirelessVideoPacket, id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard sessionID == id else { return true }
        switch packet {
        case .reset:
            resetCodec(removeImage: true)
            emit(id, .reset)
            return true
        case .accessUnit(let data):
            guard let access = WirelessH264AccessUnit.parse(data) else {
                emit(id, .failed("The wireless video stream contained an invalid frame. Restart the receiver to reconnect."))
                return false
            }
            var changed = false
            if let sps = access.sequence, sps != sequence { sequence = sps; changed = true }
            if let pps = access.picture, pps != picture { picture = pps; changed = true }
            if changed {
                format = nil
                requiresKeyframe = true
                renderer.flush()
            }
            if format == nil, let sequence, let picture {
                var description: CMFormatDescription?
                let status = sequence.withUnsafeBytes { sps in
                    picture.withUnsafeBytes { pps in
                        var pointers: [UnsafePointer<UInt8>] = [sps.bindMemory(to: UInt8.self).baseAddress!,
                                                               pps.bindMemory(to: UInt8.self).baseAddress!]
                        var sizes = [sequence.count, picture.count]
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 2,
                            parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                    }
                }
                guard status == noErr, let description else {
                    emit(id, .failed("The iPad sent an unsupported wireless video format. Restart the receiver to reconnect."))
                    return false
                }
                let size = CMVideoFormatDescriptionGetDimensions(description)
                guard size.width > 0, size.height > 0, size.width <= 8192, size.height <= 8192,
                      Int64(size.width) * Int64(size.height) <= 33_554_432 else {
                    emit(id, .failed("The wireless video dimensions exceed this viewer’s supported size."))
                    return false
                }
                format = description
                emit(id, .dimensions(size.width, size.height))
            }
            guard let format, access.containsPicture else { return true }
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush()
                requiresKeyframe = true
            }
            if requiresKeyframe && !access.isKeyframe { return true }
            // A short bounded wait allows normal decoder backpressure without
            // accumulating access units. If overloaded, keep the last image and
            // resume at a keyframe rather than displaying dependent corrupt data.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.1
            while !renderer.isReadyForMoreMediaData,
                  ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
            guard renderer.isReadyForMoreMediaData else {
                renderer.flush()
                requiresKeyframe = true
                return true
            }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                memoryBlock: nil, blockLength: access.avcc.count, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: access.avcc.count,
                flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return false }
            let copyStatus = access.avcc.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: bytes.count)
            }
            guard copyStatus == kCMBlockBufferNoErr else { return false }
            var timing = CMSampleTimingInfo(duration: .invalid,
                presentationTimeStamp: CMTime(value: frameNumber, timescale: 60), decodeTimeStamp: .invalid)
            var size = access.avcc.count
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample) == noErr, let sample else { return false }
            guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
                  CFArrayGetCount(array) > 0 else { return false }
            let attachments = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachments, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                  Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !access.isKeyframe {
                CFDictionarySetValue(attachments, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                      Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            renderer.enqueue(sample)
            requiresKeyframe = false
            frameNumber = frameNumber == Int64.max ? 0 : frameNumber + 1
            if !reportedLive { reportedLive = true; emit(id, .live) }
            return true
        }
    }
}

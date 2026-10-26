// Copyright (c) 2026 Russell Varriale (https://github.com/russellvarriale/ipad-to-mac-mirroring)
// SPDX-License-Identifier: MIT
import Foundation
import Darwin

enum WirelessVideoPacket: Sendable {
    case accessUnit(Data)
    case reset
}

enum WirelessVideoTransportError: Error {
    case unavailable
    case invalidHeader
    case invalidLength
    case truncated
    case excessivePackets
    case rejectedPacket
}

// This parser retains at most one bounded packet. It never allocates storage
// from an unchecked length, resynchronizes after corruption, or queues frames.
struct WirelessVideoFramer {
    static let maximumPayload = 16 * 1024 * 1024
    static let maximumPacketsPerChunk = 64

    private var header = Data()
    private var payload = Data()
    private var payloadLength: Int?

    mutating func consume(_ bytes: Data, receive: (WirelessVideoPacket) -> Bool) throws {
        var offset = bytes.startIndex
        var delivered = 0
        while offset < bytes.endIndex {
            if let payloadLength {
                let count = min(payloadLength - payload.count, bytes.endIndex - offset)
                payload.append(contentsOf: bytes[offset..<(offset + count)])
                offset += count
                if payload.count == payloadLength {
                    let packet = payload
                    payload = Data()
                    self.payloadLength = nil
                    delivered += 1
                    guard delivered <= Self.maximumPacketsPerChunk else {
                        throw WirelessVideoTransportError.excessivePackets
                    }
                    guard receive(.accessUnit(packet)) else {
                        throw WirelessVideoTransportError.rejectedPacket
                    }
                }
                continue
            }

            let count = min(16 - header.count, bytes.endIndex - offset)
            header.append(contentsOf: bytes[offset..<(offset + count)])
            offset += count
            guard header.count == 16 else { continue }
            guard Array(header.prefix(4)) == [0x49, 0x57, 0x56, 0x31],
                  word(at: 12) == 0 else {
                throw WirelessVideoTransportError.invalidHeader
            }
            let kind = word(at: 4)
            let length = word(at: 8)
            guard kind == 1 || kind == 2 else {
                throw WirelessVideoTransportError.invalidHeader
            }
            guard length <= UInt32(Self.maximumPayload),
                  (kind == 1 && length > 0) || (kind == 2 && length == 0) else {
                throw WirelessVideoTransportError.invalidLength
            }
            header.removeAll(keepingCapacity: true)
            if kind == 2 {
                delivered += 1
                guard delivered <= Self.maximumPacketsPerChunk else {
                    throw WirelessVideoTransportError.excessivePackets
                }
                guard receive(.reset) else {
                    throw WirelessVideoTransportError.rejectedPacket
                }
            } else {
                payloadLength = Int(length)
            }
        }
    }

    func finish() throws {
        guard header.isEmpty, payloadLength == nil, payload.isEmpty else {
            throw WirelessVideoTransportError.truncated
        }
    }

    private func word(at offset: Int) -> UInt32 {
        let start = header.startIndex + offset
        return (UInt32(header[start]) << 24) | (UInt32(header[start + 1]) << 16)
            | (UInt32(header[start + 2]) << 8) | UInt32(header[start + 3])
    }
}

// A private, inherited socketpair is the channel capability. No local listener,
// socket pathname, file, network port, or separate Screen Recording access is
// needed. The parent passes childInput as Process.standardInput (child fd 0).
final class WirelessVideoTransport: @unchecked Sendable {
    let childInput: FileHandle

    private let queue = DispatchQueue(label: "local.ipadwindow.wireless-video", qos: .userInitiated)
    private let stopLock = NSLock()
    private var stopRequested = false
    private let parentFD: Int32
    private let receive: @Sendable (WirelessVideoPacket) -> Bool
    private let failed: @Sendable (String) -> Void
    private var source: DispatchSourceRead?
    private var framer = WirelessVideoFramer()
    private var finished = false

    // receive executes synchronously on the private video queue. It must either
    // consume the packet synchronously or use its own small, enforced bound;
    // return false to close the channel when it cannot safely accept a packet.
    init(receive: @escaping @Sendable (WirelessVideoPacket) -> Bool,
         failed: @escaping @Sendable (String) -> Void) throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw WirelessVideoTransportError.unavailable
        }
        let readFD = descriptors[0]
        let childFD = descriptors[1]
        let readFlags = Darwin.fcntl(readFD, F_GETFL)
        let readDescriptorFlags = Darwin.fcntl(readFD, F_GETFD)
        let childDescriptorFlags = Darwin.fcntl(childFD, F_GETFD)
        guard readFlags >= 0, readDescriptorFlags >= 0, childDescriptorFlags >= 0,
              Darwin.fcntl(readFD, F_SETFL, readFlags | O_NONBLOCK) >= 0,
              Darwin.fcntl(readFD, F_SETFD, readDescriptorFlags | FD_CLOEXEC) >= 0,
              Darwin.fcntl(childFD, F_SETFD, childDescriptorFlags | FD_CLOEXEC) >= 0 else {
            Darwin.close(readFD)
            Darwin.close(childFD)
            throw WirelessVideoTransportError.unavailable
        }
        self.parentFD = readFD
        self.childInput = FileHandle(fileDescriptor: childFD, closeOnDealloc: true)
        self.receive = receive
        self.failed = failed
        let readSource = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        source = readSource
        readSource.setEventHandler { [weak self] in self?.drain() }
        // This is the only owner that closes the parent FD. Delayed source
        // events cannot act on a descriptor reused by a later session.
        readSource.setCancelHandler { Darwin.close(readFD) }
        readSource.resume()
    }

    func closeChildEndAfterSpawn() {
        queue.async { [self] in try? childInput.close() }
    }

    func stop() {
        // Mark expected shutdown immediately, before an already queued EOF can
        // report an error. All descriptor and parser cleanup stays on queue.
        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
        queue.async { [self] in finish(reportFailure: false) }
    }

    deinit {
        source?.cancel()
        try? childInput.close()
    }

    private var shouldStop: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }

    private func drain() {
        guard !finished else { return }
        if shouldStop { finish(reportFailure: false); return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        // Limit one queue turn as well as parser memory. A producer cannot
        // monopolize the queue indefinitely with reset packets or tiny frames.
        for _ in 0..<16 {
            if shouldStop { finish(reportFailure: false); return }
            let count = Darwin.read(parentFD, &bytes, bytes.count)
            if count > 0 {
                do {
                    try framer.consume(Data(bytes.prefix(count))) { [self] packet in
                        !shouldStop && receive(packet)
                    }
                } catch {
                    finish(reportFailure: !shouldStop)
                    return
                }
            } else if count == 0 {
                // A partial header/payload and an unexpected clean EOF both
                // end this run. Neither is silently accepted as a new stream.
                do { try framer.finish() } catch { }
                finish(reportFailure: !shouldStop)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                finish(reportFailure: !shouldStop)
                return
            }
        }
    }

    private func finish(reportFailure: Bool) {
        guard !finished else { return }
        finished = true
        source?.cancel()
        source = nil
        try? childInput.close()
        framer = WirelessVideoFramer()
        if reportFailure && !shouldStop {
            failed("The private wireless video stream stopped or could not be processed. Stop the receiver and connect again.")
        }
    }
}

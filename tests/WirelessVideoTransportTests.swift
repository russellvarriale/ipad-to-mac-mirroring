import Foundation
import Darwin

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError("FAIL: " + description) }
    checks += 1
}

private func frame(kind: UInt32 = 1, payload: Data = Data([0, 0, 0, 1, 0x65, 1, 2, 3]),
                   length: UInt32? = nil, reserved: UInt32 = 0) -> Data {
    var bytes = Data([0x49, 0x57, 0x56, 0x31])
    for value in [kind, length ?? UInt32(payload.count), reserved] {
        bytes.append(contentsOf: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                                 UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    bytes.append(payload)
    return bytes
}

private func rejects(_ data: Data, _ description: String) {
    var parser = WirelessVideoFramer()
    do {
        try parser.consume(data) { _ in true }
        check(false, description)
    } catch { check(true, description) }
}

private final class Probe: @unchecked Sendable {
    let lock = NSLock()
    let packet = DispatchSemaphore(value: 0)
    let failure = DispatchSemaphore(value: 0)
    private var received: [WirelessVideoPacket] = []
    private var failures = 0
    var reject = false
    func receive(_ value: WirelessVideoPacket) -> Bool {
        lock.lock()
        received.append(value)
        let accepted = !reject
        lock.unlock()
        packet.signal()
        return accepted
    }
    func failed(_ message: String) {
        lock.lock(); failures += 1; lock.unlock()
        failure.signal()
    }
    var packetCount: Int { lock.lock(); defer { lock.unlock() }; return received.count }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures }
}

@main
private struct WirelessVideoTransportTests {
    static func main() throws {
        let unit = Data([0, 0, 0, 1, 0x65, 1, 2, 3])
        let reset = frame(kind: 2, payload: Data())
        let sequence = reset + frame(payload: unit)
        for split in 0...sequence.count {
            var parser = WirelessVideoFramer()
            var packets = 0
            var correct = true
            let sink: (WirelessVideoPacket) -> Bool = { value in
                if packets == 0 {
                    if case .reset = value {} else { correct = false }
                } else if case .accessUnit(let data) = value {
                    correct = correct && data == unit
                } else { correct = false }
                packets += 1
                return true
            }
            try parser.consume(Data(sequence.prefix(split)), receive: sink)
            try parser.consume(Data(sequence.dropFirst(split)), receive: sink)
            try parser.finish()
            check(packets == 2 && correct, "every split preserves reset and payload")
        }
        var singleByte = WirelessVideoFramer()
        var bytePackets = 0
        for byte in sequence { try singleByte.consume(Data([byte])) { _ in bytePackets += 1; return true } }
        try singleByte.finish()
        check(bytePackets == 2, "one-byte fragmentation")

        for index in [0, 1, 2, 3, 12, 13, 14, 15] {
            var invalid = frame()
            invalid[index] ^= 0x80
            rejects(invalid, "invalid magic or reserved byte")
        }
        rejects(frame(kind: 0), "unknown zero kind")
        rejects(frame(kind: 3), "unknown kind")
        rejects(frame(kind: UInt32.max), "maximum unknown kind")
        rejects(frame(payload: Data()), "empty access unit")
        rejects(frame(kind: 2, payload: Data([1])), "nonempty reset")
        rejects(frame(payload: Data(), length: UInt32(WirelessVideoFramer.maximumPayload + 1)), "oversize before allocation")
        rejects(frame(payload: Data(), length: UInt32.max), "overflow-sized header")

        let maximum = Data(repeating: 0x65, count: WirelessVideoFramer.maximumPayload)
        var maxParser = WirelessVideoFramer()
        var maxPackets = 0
        try maxParser.consume(frame(payload: maximum)) { value in
            if case .accessUnit(let data) = value, data.count == maximum.count { maxPackets += 1 }
            return true
        }
        try maxParser.finish()
        check(maxPackets == 1, "exact maximum accepted")

        for count in 1..<frame().count {
            var parser = WirelessVideoFramer()
            try parser.consume(Data(frame().prefix(count))) { _ in true }
            do { try parser.finish(); check(false, "truncated EOF") }
            catch { check(true, "truncated EOF") }
        }
        var rejected = WirelessVideoFramer()
        var rejectedCount = 0
        do {
            try rejected.consume(frame() + frame()) { _ in rejectedCount += 1; return false }
            check(false, "consumer rejection closes parser turn")
        } catch { check(rejectedCount == 1, "consumer rejection prevents later callback") }
        rejects(Data((0...WirelessVideoFramer.maximumPacketsPerChunk).flatMap { _ in Array(reset) }), "reset flood work bound")

        // Real AF_UNIX channel and immediate EOF exercise the DispatchSource,
        // rather than testing only a copied framing implementation.
        let probe = Probe()
        let transport = try WirelessVideoTransport(receive: { probe.receive($0) }, failed: { probe.failed($0) })
        var noSignal: Int32 = 1
        _ = setsockopt(transport.childInput.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        try transport.childInput.write(contentsOf: sequence)
        check(probe.packet.wait(timeout: .now() + 3) == .success, "socket reset delivered")
        check(probe.packet.wait(timeout: .now() + 3) == .success, "socket access unit delivered")
        transport.closeChildEndAfterSpawn()
        check(probe.failure.wait(timeout: .now() + 3) == .success, "unexpected EOF reported")
        transport.stop()
        check(probe.packetCount == 2 && probe.failureCount == 1, "single terminal EOF failure")

        let stoppedProbe = Probe()
        let stopped = try WirelessVideoTransport(receive: { stoppedProbe.receive($0) }, failed: { stoppedProbe.failed($0) })
        stopped.stop()
        stopped.closeChildEndAfterSpawn()
        check(stoppedProbe.failure.wait(timeout: .now() + 0.15) == .timedOut, "expected stop suppresses EOF failure")

        let rejectingProbe = Probe()
        rejectingProbe.reject = true
        let rejecting = try WirelessVideoTransport(receive: { rejectingProbe.receive($0) }, failed: { rejectingProbe.failed($0) })
        try rejecting.childInput.write(contentsOf: frame() + frame())
        check(rejectingProbe.failure.wait(timeout: .now() + 3) == .success, "consumer overload fails channel")
        check(rejectingProbe.packetCount == 1 && rejectingProbe.failureCount == 1, "consumer failure stays bounded")
        rejecting.stop()

        // Process.standardInput must duplicate a socket for writes at child fd0.
        // This local fixture neither listens on a network nor records media.
        if CommandLine.arguments.count == 2 {
            let processProbe = Probe()
            let channel = try WirelessVideoTransport(receive: { processProbe.receive($0) }, failed: { processProbe.failed($0) })
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
            child.standardInput = channel.childInput
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            channel.closeChildEndAfterSpawn()
            check(processProbe.packet.wait(timeout: .now() + 3) == .success, "child fd0 reset delivered")
            check(processProbe.packet.wait(timeout: .now() + 3) == .success, "child fd0 access unit delivered")
            check(processProbe.failure.wait(timeout: .now() + 3) == .success, "child EOF delivered after data")
            child.waitUntilExit()
            check(child.terminationStatus == 0 && processProbe.packetCount == 2 && processProbe.failureCount == 1, "child socket duplicated correctly and drains before EOF")
            channel.stop()
        }
        print("PASS: \(checks) wireless video transport checks; no network, recording, or UI launch.")
    }
}

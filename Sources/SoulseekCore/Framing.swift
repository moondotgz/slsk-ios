import Foundation

/// Wire framing for all Soulseek connection types.
///
/// Every frame is `[uint32 length][code][payload]` where `length` counts the
/// bytes AFTER the length field itself (i.e. code size + payload size).
/// Code sizes differ per connection type:
/// - Server:     4-byte code (including 1001/1003)
/// - Peer:       4-byte code
/// - Peer init:  1-byte code (PierceFirewall = 0, PeerInit = 1)
/// - Distributed: 1-byte code
public enum Frame {
    public static func server(code: UInt32, payload: [UInt8] = []) -> Data {
        frame(codeSize: 4, code: UInt64(code), payload: payload)
    }

    public static func peer(code: UInt32, payload: [UInt8] = []) -> Data {
        frame(codeSize: 4, code: UInt64(code), payload: payload)
    }

    public static func initMessage(code: UInt8, payload: [UInt8] = []) -> Data {
        frame(codeSize: 1, code: UInt64(code), payload: payload)
    }

    public static func distributed(code: UInt8, payload: [UInt8] = []) -> Data {
        frame(codeSize: 1, code: UInt64(code), payload: payload)
    }

    private static func frame(codeSize: Int, code: UInt64, payload: [UInt8]) -> Data {
        var buffer = MessageBuffer()
        buffer.writeUInt32(UInt32(codeSize + payload.count))
        var codeBuffer = MessageBuffer()
        if codeSize == 4 {
            codeBuffer.writeUInt32(UInt32(truncatingIfNeeded: code))
        } else {
            codeBuffer.writeByte(UInt8(truncatingIfNeeded: code))
        }
        buffer.writeBytes(codeBuffer.bytes)
        buffer.writeBytes(payload)
        return buffer.data
    }
}

/// Incrementally reassembles complete frames from a raw TCP byte stream.
/// Yields the frame body (code + payload) without the 4-byte length prefix.
public struct FrameAssembler {
    public var maximumFrameSize: Int = 448 * 1024 * 1024

    private var pending: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data, handler: (Data) -> Void) throws {
        append(data)
        while let body = try nextFrame() {
            handler(body)
        }
    }

    public mutating func append(_ data: Data) {
        pending.append(contentsOf: [UInt8](data))
    }

    public mutating func nextFrame() throws -> Data? {
        if pending.count >= 4 {
            let length = Int(pending[0])
                | (Int(pending[1]) << 8)
                | (Int(pending[2]) << 16)
                | (Int(pending[3]) << 24)

            guard length >= 1, length <= maximumFrameSize else {
                throw SlskError.protocolViolation("frame length \(length) out of bounds")
            }
            guard pending.count >= 4 + length else { return nil }

            let body = Data(pending[4 ..< 4 + length])
            pending.removeFirst(4 + length)
            return body
        }
        return nil
    }

    public mutating func takePendingBytes() -> Data {
        let bytes = Data(pending)
        pending.removeAll()
        return bytes
    }

    public mutating func reset() {
        pending.removeAll()
    }
}

/// Monotonically increasing token source, seeded randomly per session the
/// same way Nicotine+ does (`initial_token` + `increment_token`).
public final class TokenGenerator {
    private var value: UInt32
    private let lock = NSLock()

    public init() {
        var generator = SystemRandomNumberGenerator()
        value = UInt32.random(in: 0 ..< (UInt32.max / 1000), using: &generator)
    }

    public func next() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        value = value >= UInt32.max ? 0 : value + 1
        return value
    }
}

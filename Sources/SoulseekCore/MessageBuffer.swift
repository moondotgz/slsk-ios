import Foundation

/// Little-endian buffer used to build and parse Soulseek protocol messages.
///
/// Wire conventions (verified against Nicotine+ `pynicotine/slskmessages.py`):
/// - Integers are little-endian; strings are `uint32` byte length + UTF-8
///   (Latin-1 fallback when decoding legacy payloads).
/// - IP addresses are 4 bytes in reverse octet order.
public struct MessageBuffer {
    public private(set) var bytes: [UInt8]
    private var offset: Int

    public init() {
        bytes = []
        offset = 0
    }

    public init(_ data: Data) {
        bytes = [UInt8](data)
        offset = 0
    }

    public init(bytes: [UInt8]) {
        self.bytes = bytes
        offset = 0
    }

    // MARK: Reading

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { remaining == 0 }
    /// Current read position (for look-ahead parsing).
    public var position: Int { offset }

    /// Absolute-index byte peek without consuming.
    public func peekByte(atIndex index: Int) -> UInt8? {
        index >= 0 && index < bytes.count ? bytes[index] : nil
    }

    public mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw SlskError.truncated("uint8") }
        let value = bytes[offset]
        offset += 1
        return value
    }

    public mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else { throw SlskError.truncated("uint16") }
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SlskError.truncated("uint32") }
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(bytes[offset]) << shift
            offset += 1
        }
        return value
    }

    public mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw SlskError.truncated("uint64") }
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            value |= UInt64(bytes[offset]) << shift
            offset += 1
        }
        return value
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readBool() throws -> Bool {
        try readByte() != 0
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard remaining >= count else { throw SlskError.truncated("bytes(\(count))") }
        let slice = Array(bytes[offset ..< offset + count])
        offset += count
        return slice
    }

    /// `uint32` length + UTF-8 payload (Latin-1 fallback).
    public mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        let raw = try readBytes(length)
        let data = Data(raw)
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(data: data, encoding: .isoLatin1)
            ?? String(decoding: raw, as: UTF8.self)
    }

    /// 4 reversed octets → dotted quad.
    public mutating func readIPAddress() throws -> String {
        let raw = try readBytes(4)
        return "\(raw[3]).\(raw[2]).\(raw[1]).\(raw[0])"
    }

    public mutating func readRemaining() -> [UInt8] {
        let slice = Array(bytes[offset...])
        offset = bytes.count
        return slice
    }

    // MARK: Writing

    public mutating func writeByte(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func writeBool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    public mutating func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    public mutating func writeUInt32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
    }

    public mutating func writeUInt64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
    }

    public mutating func writeInt32(_ value: Int32) {
        writeUInt32(UInt32(bitPattern: value))
    }

    public mutating func writeString(_ value: String) {
        let encoded = Array(value.utf8)
        writeUInt32(UInt32(encoded.count))
        bytes.append(contentsOf: encoded)
    }

    public mutating func writeBytes(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    public mutating func writeData(_ value: Data) {
        bytes.append(contentsOf: [UInt8](value))
    }

    /// Dotted quad → 4 reversed octets.
    public mutating func writeIPAddress(_ value: String) {
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        let padded = octets.count == 4 ? octets : [0, 0, 0, 0]
        bytes.append(padded[3])
        bytes.append(padded[2])
        bytes.append(padded[1])
        bytes.append(padded[0])
    }

    // MARK: Output

    public var data: Data { Data(bytes) }
}

extension MessageBuffer {
    /// Advance without interpreting bytes (used by the 2 GiB size workaround).
    public mutating func advance(_ count: Int) {
        offset = min(bytes.count, offset + count)
    }
}

public enum SlskError: Error, Equatable {
    case truncated(String)
    case protocolViolation(String)
    case compressionFailed(String)
    case notConnected
    case loginFailed(String)
    case connectionFailed(String)
    case invalidState(String)

    public var localizedDescription: String {
        switch self {
        case let .truncated(field): "Truncated message while reading \(field)"
        case let .protocolViolation(message): "Protocol violation: \(message)"
        case let .compressionFailed(message): "Compression failed: \(message)"
        case .notConnected: "Not connected to the server"
        case let .loginFailed(reason): "Login failed: \(reason)"
        case let .connectionFailed(message): "Connection failed: \(message)"
        case let .invalidState(message): "Invalid state: \(message)"
        }
    }
}

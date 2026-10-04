import Foundation

/// A single shared/remote file with its audio attributes.
public struct RemoteFileInfo: Equatable, Identifiable {
    public var id: String { virtualPath }
    public let virtualPath: String
    public let size: UInt64
    public let bitrate: UInt32?
    public let duration: UInt32?
    public let vbr: UInt32?
    public let sampleRate: UInt32?
    public let bitDepth: UInt32?

    public init(virtualPath: String, size: UInt64, bitrate: UInt32? = nil, duration: UInt32? = nil,
                vbr: UInt32? = nil, sampleRate: UInt32? = nil, bitDepth: UInt32? = nil) {
        self.virtualPath = virtualPath
        self.size = size
        self.bitrate = bitrate
        self.duration = duration
        self.vbr = vbr
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    public var folder: String {
        virtualPath.contains("\\")
            ? String(virtualPath[..<virtualPath.lastIndex(of: "\\")!])
            : virtualPath
    }

    public var fileName: String {
        virtualPath.contains("\\")
            ? String(virtualPath[virtualPath.index(after: virtualPath.lastIndex(of: "\\")!)...])
            : virtualPath
    }

    public var fileExtension: String {
        fileName.contains(".") ? String(fileName[fileName.index(after: fileName.lastIndex(of: ".")!)...]) : ""
    }

    public var durationSeconds: UInt32? {
        if let duration { return duration }
        guard let bitrate, bitrate > 0 else { return nil }
        return UInt32(min(UInt64(UInt32.max), size / (UInt64(bitrate) * 125)))
    }
}

/// Encode/decode the repeating "file entry" structure used by search
/// responses, share lists and folder contents. Mirrors Nicotine+'s
/// `FileListMessage.pack_file_info` and `unpack_file_size` (Soulseek NS
/// 2 GiB bug workaround included).
public enum FileListCodec {
    public static func packFileInfo(_ file: RemoteFileInfo, into b: inout MessageBuffer, includeFolder: Bool = true) {
        b.writeByte(1)
        b.writeString(includeFolder ? file.virtualPath : file.fileName)
        b.writeUInt64(file.size)
        b.writeUInt32(0) // obsolete "ext" field
        var attributes = MessageBuffer()
        var count: UInt32 = 0
        if let bitrate = file.bitrate {
            attributes.writeUInt32(0)
            attributes.writeUInt32(bitrate)
            count += 1
        }
        if let duration = file.duration {
            attributes.writeUInt32(1)
            attributes.writeUInt32(duration)
            count += 1
        }
        if let vbr = file.vbr {
            attributes.writeUInt32(2)
            attributes.writeUInt32(vbr)
            count += 1
        }
        if let sampleRate = file.sampleRate {
            attributes.writeUInt32(4)
            attributes.writeUInt32(sampleRate)
            count += 1
        }
        if let bitDepth = file.bitDepth {
            attributes.writeUInt32(5)
            attributes.writeUInt32(bitDepth)
            count += 1
        }
        b.writeUInt32(count)
        b.writeBytes(attributes.bytes)
    }

    /// Parse a list of `count` file entries.
    public static func parseFiles(count: UInt32, from b: inout MessageBuffer, folder: String? = nil) throws -> [RemoteFileInfo] {
        var files: [RemoteFileInfo] = []
        files.reserveCapacity(Int(min(count, 100_000)))
        for _ in 0 ..< count {
            _ = try b.readByte() // code, always 1 in practice
            let name = try b.readString()
            let size = try readFileSize(&b)
            let obsoleteExtLength = Int(try b.readUInt32())
            if obsoleteExtLength > 0 {
                _ = try b.readBytes(obsoleteExtLength)
            }
            let attributeCount = try b.readUInt32()
            var bitrate: UInt32?
            var duration: UInt32?
            var vbr: UInt32?
            var sampleRate: UInt32?
            var bitDepth: UInt32?
            for _ in 0 ..< attributeCount {
                let key = try b.readUInt32()
                let value = try b.readUInt32()
                switch key {
                case 0: bitrate = value
                case 1: duration = value
                case 2: vbr = value
                case 4: sampleRate = value
                case 5: bitDepth = value
                default: break
                }
            }
            var path = name.replacingOccurrences(of: "/", with: "\\")
            // SharedFileListResponse/FolderContentsResponse use basenames, unlike search responses.
            if let folder, !path.contains("\\") {
                path = folder.replacingOccurrences(of: "/", with: "\\") + "\\" + path
            }
            files.append(RemoteFileInfo(
                virtualPath: path,
                size: size, bitrate: bitrate, duration: duration, vbr: vbr,
                sampleRate: sampleRate, bitDepth: bitDepth
            ))
        }
        return files
    }

    /// Soulseek NS reports sizes > 2 GiB as `uint32 size + uint32 0xFFFFFFFF`;
    /// detect the garbage tail and read only the low 4 bytes.
    private static func readFileSize(_ b: inout MessageBuffer) throws -> UInt64 {
        guard b.remaining >= 8 else { throw SlskError.truncated("file size") }
        if b.peekByte(atIndex: b.position + 7) == 255 {
            let low = try b.readUInt32()
            b.advance(4)
            return UInt64(low)
        }
        return try b.readUInt64()
    }
}

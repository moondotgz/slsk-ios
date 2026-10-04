import XCTest
@testable import SoulseekCore

final class MD5Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(MD5.hexDigest(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hexDigest("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hexDigest("The quick brown fox jumps over the lazy dog"),
                       "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(MD5.hexDigest("user1pass"), MD5.hexDigest("user1pass"))
    }
}

final class MessageBufferTests: XCTestCase {
    func testRoundtripPrimitives() throws {
        var buffer = MessageBuffer()
        buffer.writeUInt32(0xDEADBEEF)
        buffer.writeUInt64(UInt64.max)
        buffer.writeUInt16(0xBEEF)
        buffer.writeByte(7)
        buffer.writeBool(true)
        buffer.writeInt32(-42)
        buffer.writeString("hello \\ folder\\song.mp3")

        var reader = buffer
        XCTAssertEqual(try reader.readUInt32(), 0xDEADBEEF)
        XCTAssertEqual(try reader.readUInt64(), UInt64.max)
        XCTAssertEqual(try reader.readUInt16(), 0xBEEF)
        XCTAssertEqual(try reader.readByte(), 7)
        XCTAssertEqual(try reader.readBool(), true)
        XCTAssertEqual(try reader.readInt32(), -42)
        XCTAssertEqual(try reader.readString(), "hello \\ folder\\song.mp3")
        XCTAssertTrue(reader.isAtEnd)
    }

    func testIPAddressReversal() throws {
        var buffer = MessageBuffer()
        buffer.writeIPAddress("10.0.1.23")
        XCTAssertEqual(buffer.bytes, [23, 1, 0, 10])
        var reader = buffer
        XCTAssertEqual(try reader.readIPAddress(), "10.0.1.23")
    }

    func testTruncationThrows() {
        var buffer = MessageBuffer()
        buffer.writeByte(1)
        XCTAssertThrowsError(try buffer.readUInt32())
    }
}

final class FramingTests: XCTestCase {
    func testServerFrameLengthSemantics() {
        // length excludes the 4 length bytes but includes the 4-byte code
        let frame = Frame.server(code: ServerCode.setWaitPort, payload: [1, 2, 3, 4])
        XCTAssertEqual([UInt8](frame.prefix(4)), [8, 0, 0, 0]) // 4 code + 4 payload
        let code = UInt32(frame[4]) | (UInt32(frame[5]) << 8) | (UInt32(frame[6]) << 16) | (UInt32(frame[7]) << 24)
        XCTAssertEqual(code, ServerCode.setWaitPort)
    }

    func testInitFrameUsesOneByteCode() {
        let frame = Frame.initMessage(code: PeerInitCode.pierceFirewall.rawValue, payload: [9, 9, 9, 9])
        XCTAssertEqual([UInt8](frame.prefix(4)), [5, 0, 0, 0])
        XCTAssertEqual(frame[4], 0)
    }

    func testAssemblerReassemblesAcrossChunks() throws {
        var assembler = FrameAssembler()
        var received: [Data] = []

        let first = Frame.server(code: ServerCode.login, payload: [1, 2, 3])
        let second = Frame.peer(code: PeerCode.queueUpload, payload: [UInt8](Data("file.mp3".utf8)))
        let combined = first + second

        // Feed in awkward chunks; the first frame (11 bytes) completes mid-chunk
        try assembler.feed(combined.prefix(3)) { received.append($0) }
        XCTAssertTrue(received.isEmpty)
        try assembler.feed(combined.dropFirst(3).prefix(10)) { received.append($0) }
        XCTAssertEqual(received.count, 1)
        try assembler.feed(combined.dropFirst(13)) { received.append($0) }

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0], first.dropFirst(4))
        XCTAssertEqual(received[1], second.dropFirst(4))
    }

    func testAssemblerRejectsOversizedFrame() {
        var assembler = FrameAssembler()
        assembler.maximumFrameSize = 16
        var oversized = MessageBuffer()
        oversized.writeUInt32(1000)
        XCTAssertThrowsError(try assembler.feed(oversized.data) { _ in })
    }
}

final class MessageRoundtripTests: XCTestCase {
    func testLoginPacketLayout() {
        let packet = ServerOut.login(username: "tester", password: "hunter2")
        var buffer = MessageBuffer(packet)

        // Length prefix
        let length = try? buffer.readUInt32()
        XCTAssertEqual(length, UInt32(packet.count - 4))
        // Code
        XCTAssertEqual(try buffer.readUInt32(), ServerCode.login)
        // Fields
        XCTAssertEqual(try buffer.readString(), "tester")
        XCTAssertEqual(try buffer.readString(), "hunter2")
        XCTAssertEqual(try buffer.readUInt32(), ServerOut.majorVersion)
        XCTAssertEqual(try buffer.readString(), MD5.hexDigest("testerhunter2"))
        XCTAssertEqual(try buffer.readUInt32(), ServerOut.minorVersion)
        XCTAssertTrue(buffer.isAtEnd)
    }

    func testTransferRequestUploadIncludesFileSize() throws {
        let packet = PeerOut.transferRequest(direction: TransferDirection.upload,
                                             token: 42, file: "\\music\\a.mp3", fileSize: 1024)
        var buffer = MessageBuffer(packet)
        XCTAssertEqual(try buffer.readUInt32(), UInt32(packet.count - 4))
        XCTAssertEqual(try buffer.readUInt32(), PeerCode.transferRequest)
        XCTAssertEqual(try buffer.readUInt32(), TransferDirection.upload)
        XCTAssertEqual(try buffer.readUInt32(), 42)
        XCTAssertEqual(try buffer.readString(), "\\music\\a.mp3")
        XCTAssertEqual(try buffer.readUInt64(), 1024)
        XCTAssertTrue(buffer.isAtEnd)
    }

    func testTransferRequestDownloadOmitsFileSize() throws {
        let packet = PeerOut.transferRequest(direction: TransferDirection.download,
                                             token: 42, file: "\\a.mp3")
        var buffer = MessageBuffer(packet.dropFirst(8))
        XCTAssertEqual(try buffer.readUInt32(), TransferDirection.download)
        XCTAssertEqual(try buffer.readUInt32(), 42)
        XCTAssertEqual(try buffer.readString(), "\\a.mp3")
        XCTAssertTrue(buffer.isAtEnd)
    }

    func testTransferResponseRejectWithReason() throws {
        let packet = PeerOut.transferResponse(token: 7, allowed: false, reason: "Queued")
        var buffer = MessageBuffer(packet.dropFirst(8))
        XCTAssertEqual(try buffer.readUInt32(), 7)
        XCTAssertEqual(try buffer.readBool(), false)
        XCTAssertEqual(try buffer.readString(), "Queued")
        XCTAssertTrue(buffer.isAtEnd)
    }
}

final class ZlibTests: XCTestCase {
    func testRoundtrip() throws {
        let payload = Data("search response payload \(String(repeating: "x", count: 5000))".utf8)
        let compressed = try Zlib.compress(payload)
        XCTAssertLessThan(compressed.count, payload.count)
        let decompressed = try Zlib.decompress(compressed)
        XCTAssertEqual(decompressed, payload)
    }

    func testDecompressEnforcesLimit() throws {
        let payload = Data(repeating: 0x41, count: 100_000)
        let compressed = try Zlib.compress(payload)
        XCTAssertThrowsError(try Zlib.decompress(compressed, maxOutput: 1024))
    }
}

final class FileListCodecTests: XCTestCase {
    func testPackParseRoundtrip() throws {
        let file = RemoteFileInfo(virtualPath: "\\Music\\Album\\track.mp3", size: 8_000_000,
                                  bitrate: 320, duration: 240, vbr: 1)
        var buffer = MessageBuffer()
        FileListCodec.packFileInfo(file, into: &buffer)

        let files = try FileListCodec.parseFiles(count: 1, from: &buffer)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].virtualPath, "\\Music\\Album\\track.mp3")
        XCTAssertEqual(files[0].size, 8_000_000)
        XCTAssertEqual(files[0].bitrate, 320)
        XCTAssertEqual(files[0].duration, 240)
        XCTAssertEqual(files[0].vbr, 1)
    }

    func testSoulseekNSLargeFileSizeBug() throws {
        // >2 GiB sizes arrive as uint32 size + uint32 0xFFFFFFFF garbage tail
        var buffer = MessageBuffer()
        buffer.writeByte(1)
        buffer.writeString("\\big\\file.flac")
        buffer.writeUInt32(3_000_000_000) // truncated 32-bit size
        buffer.writeUInt32(UInt32.max)    // garbage
        buffer.writeUInt32(0)             // obsolete ext
        buffer.writeUInt32(0)             // attribute count

        let files = try FileListCodec.parseFiles(count: 1, from: &buffer)
        XCTAssertEqual(files[0].size, 3_000_000_000)
        XCTAssertTrue(buffer.isAtEnd)
    }
}

final class SearchQueryTests: XCTestCase {
    func testTokenizesIncludedAndExcluded() {
        let query = SearchQuery("radiohead -live \"ok computer\" -\"rain down\"")
        XCTAssertEqual(query.includedWords, ["radiohead"])
        XCTAssertEqual(query.excludedWords, ["live"])
        XCTAssertTrue(query.includedPhrases.contains("ok computer"))
        XCTAssertTrue(query.excludedPhrases.contains("rain down"))
    }

    func testEmptyQueryHasNoIncludedWords() {
        XCTAssertTrue(SearchQuery("   ").includedWords.isEmpty)
        XCTAssertTrue(SearchQuery("-only").includedWords.isEmpty)
    }
}

final class SharesManagerTests: XCTestCase {
    func testSearchMatchingIsCaseInsensitiveAndExcludes() throws {
        let shares = SharesManager()
        shares.setSharedDirectories([FileManager.default.temporaryDirectory
            .appendingPathComponent("slsk-test-\(UUID().uuidString)")])

        // Seed the index directly through a scan of a temp tree.
        let root = shares.shareRoots.values.first!
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Artist"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("Artist/Song ONE.mp3").path, contents: Data(repeating: 0, count: 10))
        FileManager.default.createFile(atPath: root.appendingPathComponent("Artist/other.flac").path, contents: Data(repeating: 0, count: 10))

        let scanExpectation = expectation(description: "scan")
        shares.rescan { scanExpectation.fulfill() }
        wait(for: [scanExpectation], timeout: 10)

        let hits = shares.search(query: SearchQuery("song one"))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].fileName, "Song ONE.mp3")

        let excluded = shares.search(query: SearchQuery("artist -flac"))
        XCTAssertTrue(excluded.allSatisfy { $0.fileExtension == "mp3" })

        let browse = try shares.browseResponseData()
        let decompressed = try Zlib.decompress(browse)
        XCTAssertGreaterThan(decompressed.count, 0)
    }
}

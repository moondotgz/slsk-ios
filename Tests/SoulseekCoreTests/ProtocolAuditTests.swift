import Foundation
import XCTest
@testable import SoulseekCore

final class ProtocolAuditTests: XCTestCase {
    func testNegativeByteCountIsRejectedWithoutMovingReader() throws {
        var buffer = MessageBuffer(bytes: [42])
        XCTAssertThrowsError(try buffer.readBytes(-1))
        buffer.advance(-1)
        XCTAssertEqual(try buffer.readByte(), 42)
    }

    func testShareScanDoesNotFollowSymlinksOrExposeHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("visible.mp3"))
        try Data([2]).write(to: root.appendingPathComponent(".secret"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let shares = SharesManager()
        shares.setSharedDirectories([root])
        let scanned = expectation(description: "scan finished without following link")
        shares.rescan { scanned.fulfill() }
        wait(for: [scanned], timeout: 2)
        XCTAssertEqual(shares.sharedFileCount, 1)
        XCTAssertEqual(shares.fileMap.keys.first?.split(separator: "\\").last, "visible.mp3")
    }

    func testBrowseEntriesUseBasenamesAndReconstructDownloadPaths() throws {
        let file = RemoteFileInfo(virtualPath: "\\music\\song.mp3", size: 10, bitrate: 320)
        var packed = MessageBuffer()
        FileListCodec.packFileInfo(file, into: &packed, includeFolder: false)
        var wire = packed
        XCTAssertEqual(try wire.readByte(), 1)
        XCTAssertEqual(try wire.readString(), "song.mp3")
        XCTAssertEqual(try FileListCodec.parseFiles(count: 1, from: &packed, folder: "\\music"), [file])
    }

    func testDurationEstimateDoesNotOverflow() {
        XCTAssertEqual(RemoteFileInfo(virtualPath: "file", size: UInt64.max, bitrate: 1).durationSeconds, UInt32.max)
    }

    func testChatMessageIDsAreUniqueAcrossFeedsAndHistoryReloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Storage(baseURL: directory)
        let chat = ChatManager()
        chat.addRoomMessage(room: "room", username: "peer", text: "first", isSelf: false)
        chat.addPrivateMessage(username: "peer", text: "second", isSelf: false)
        chat.addGlobalFeedMessage(room: "room", username: "peer", text: "third")
        chat.addRoomMessage(room: "room", username: "peer", text: "fourth", isSelf: false)
        let ids = chat.room(named: "room")!.messages.map(\.id)
            + chat.messages(for: "peer").map(\.id) + chat.globalRoomMessages.map(\.id)
        XCTAssertEqual(Set(ids).count, 4)
        chat.saveHistory(storage: storage)
        let restored = ChatManager()
        restored.loadHistory(storage: storage)
        restored.addPrivateMessage(username: "peer", text: "fifth", isSelf: false)
        XCTAssertGreaterThan(restored.messages(for: "peer").last!.id, ids.max()!)
        let legacy = ChatMessage(id: 1, username: "peer", text: "legacy", timestamp: Date(), isSelf: false)
        storage.save(["peer": [legacy, legacy]], as: "private-chat")
        let migrated = ChatManager()
        migrated.loadHistory(storage: storage)
        let historyIDs = migrated.room(named: "room")!.messages.map(\.id) + migrated.messages(for: "peer").map(\.id)
        XCTAssertEqual(Set(historyIDs).count, historyIDs.count)
    }

    func testWishlistRotatesOneItemAndRegistersReusableSearchTokens() throws {
        let search = SearchEngine()
        search.setWishlist(["alpha", "beta"])
        search.setWishlistInterval(60)
        defer { search.setWishlistInterval(0) }
        var requests: [(UInt32, String)] = []
        search.onWishlistSearch { requests.append(($0, $1)) }
        search.performWishlistSearch()
        search.performWishlistSearch()
        search.performWishlistSearch()
        XCTAssertEqual(requests.map { $0.1 }, ["alpha", "beta", "alpha"])
        XCTAssertEqual(requests[0].0, requests[2].0)
        XCTAssertEqual(search.sessions.count, 2)
        var result = MessageBuffer()
        result.writeString("peer")
        result.writeUInt32(requests[0].0)
        result.writeUInt32(1)
        FileListCodec.packFileInfo(RemoteFileInfo(virtualPath: "alpha.mp3", size: 10), into: &result)
        result.writeBool(true)
        result.writeUInt32(10)
        result.writeUInt32(0)
        try search.handleSearchResponse(username: "peer", body: result, isBanned: { _ in false })
        XCTAssertEqual(search.sessions[requests[0].0]?.hits.count, 1)
        search.setWishlistInterval(0)
        search.performWishlistSearch()
        XCTAssertEqual(requests.count, 3)
    }

    func testDistributedAdoptionAnnouncesParentAndRecoversWhenParentDisconnects() throws {
        let distributed = DistributedManager()
        distributed.localUsername = "self"
        var messages: [Data] = []
        distributed.onSendToServer = { messages.append($0) }
        distributed.announceInitialState()
        XCTAssertEqual(distributed.branchRoot, "self")
        var level = MessageBuffer()
        level.writeInt32(0)
        _ = distributed.handleDistribMessage(code: 4, body: level, from: "parent", connectionID: 1, isParentCandidate: true)
        var search = MessageBuffer()
        search.writeUInt32(49)
        search.writeString("searcher")
        search.writeUInt32(123)
        search.writeString("music")
        XCTAssertEqual(distributed.handleDistribMessage(code: 3, body: search, from: "parent", connectionID: 1, isParentCandidate: true), search.bytes)
        XCTAssertEqual(distributed.parentUsername, "parent")
        XCTAssertTrue(messages.contains(ServerOut.haveNoParent(false)))
        XCTAssertNil(distributed.handleDistribMessage(code: 3, body: search, from: "child", connectionID: 2, isParentCandidate: false))
        distributed.handleChildDisconnected("parent")
        XCTAssertNil(distributed.parentUsername)
        XCTAssertEqual(distributed.branchRoot, "self")
        XCTAssertTrue(messages.contains(ServerOut.haveNoParent(true)))
    }

    func testDistributedChildLimitUsesServerRatioAndCap() {
        let distributed = DistributedManager()
        distributed.parentMinSpeed = 100
        distributed.parentSpeedRatio = 10
        distributed.uploadSpeed = 99
        XCTAssertEqual(distributed.maxChildren, 0)
        distributed.uploadSpeed = 2500
        XCTAssertEqual(distributed.maxChildren, 2)
        distributed.uploadSpeed = 100_000
        XCTAssertEqual(distributed.maxChildren, 10)
    }
}

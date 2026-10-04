import Foundation
import XCTest
@testable import SoulseekCore

private final class TransferGateway: PeerGateway {
    var messages: [Data] = []
    var fileData = Data()
    var closed: [UInt64] = []
    var pendingSend: (((any Error)?) -> Void)?
    var deferSends = false
    func sendToPeer(_ username: String, _ data: Data) { messages.append(data) }
    func requestPeerAddress(_ username: String) {}
    func peerAddress(for username: String) -> (host: String, port: UInt16)? { nil }
    func setPeerAddress(_ username: String, host: String, port: UInt16) {}
    func isUserOnline(_ username: String) -> Bool { false }
    func requestIndirectConnection(_ username: String, type: String, token: UInt32) {}
    func sendCantConnectToPeer(token: UInt32, username: String) {}
    func openUploadConnection(username: String, token: UInt32) -> UInt64? { nil }
    func sendFileData(_ connectionID: UInt64, _ data: Data, completion: @escaping ((any Error)?) -> Void) {
        fileData.append(data)
        if deferSends { pendingSend = completion }
        else { DispatchQueue.main.async { completion(nil) } }
    }
    func sendFileOffset(_ connectionID: UInt64, _ offset: UInt64) {}
    func closeFileConnection(_ connectionID: UInt64) { closed.append(connectionID) }
    func sendToDistributedChildren(_ data: Data) {}
    func connectToParentCandidate(username: String, host: String, port: UInt16) {}
    func rejectParentCandidates() {}
}

final class TransferRegressionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func upload(_ bytes: Data, gateway: TransferGateway) throws -> (TransferManager, UploadItem, UInt32) {
        let root = try temporaryDirectory()
        try bytes.write(to: root.appendingPathComponent("upload.bin"))
        let shares = SharesManager()
        shares.setSharedDirectories([root])
        let scanned = expectation(description: "shares scanned")
        shares.rescan { scanned.fulfill() }
        wait(for: [scanned], timeout: 3)
        let manager = TransferManager()
        manager.gateway = gateway
        manager.shares = shares
        _ = manager.handleQueueUpload(file: shares.fileMap.keys.first!, from: "peer")
        var offer = MessageBuffer(gateway.messages.last!)
        _ = try offer.readUInt32()
        XCTAssertEqual(try offer.readUInt32(), PeerCode.transferRequest)
        _ = try offer.readUInt32()
        let token = try offer.readUInt32()
        return (manager, manager.uploads[0], token)
    }

    func testUploadSendsEntireFileAndResumesAtOffset() throws {
        let bytes = Data((0..<(1024 * 1024 + 13)).map { UInt8(truncatingIfNeeded: $0) })
        for offset: UInt64 in [0, 12345] {
            let gateway = TransferGateway()
            let (manager, item, token) = try upload(bytes, gateway: gateway)
            manager.handleTransferResponse(token: token, allowed: true, reason: nil, from: "peer")
            manager.handleUploadConnectionOpened(connectionID: 1, username: "peer", token: token)
            let finished = expectation(description: "upload finished")
            manager.onChanged = { if item.status == .finished { finished.fulfill() } }
            manager.handleUploadOffset(connectionID: 1, offset: offset)
            wait(for: [finished], timeout: 3)
            XCTAssertEqual(gateway.fileData, Data(bytes.dropFirst(Int(offset))))
            XCTAssertEqual(manager.activeUploadCount, 0)
            XCTAssertEqual(gateway.closed, [1])
        }
    }

    func testUploadWaitsForSendCompletionAndReportsFailure() throws {
        let gateway = TransferGateway()
        gateway.deferSends = true
        let (manager, item, token) = try upload(Data(repeating: 7, count: 32), gateway: gateway)
        manager.handleUploadConnectionOpened(connectionID: 1, username: "peer", token: token)
        manager.handleUploadOffset(connectionID: 1, offset: 0)
        XCTAssertEqual(item.status, .transferring)
        XCTAssertEqual(item.currentOffset, 0)
        XCTAssertTrue(gateway.closed.isEmpty)
        gateway.pendingSend?(SlskError.notConnected)
        XCTAssertEqual(item.status, .failed("File read error."))
        XCTAssertEqual(manager.activeUploadCount, 0)
        XCTAssertEqual(gateway.closed, [1])
    }

    func testUploadTimeoutReleasesSlotWhileWaitingForOffset() throws {
        let gateway = TransferGateway()
        let (manager, item, token) = try upload(Data([1]), gateway: gateway)
        manager.activationTimeout = 0.01
        manager.handleUploadConnectionOpened(connectionID: 1, username: "peer", token: token)
        let timedOut = expectation(description: "upload timed out")
        manager.onChanged = { if item.status == .failed("Connection timeout") { timedOut.fulfill() } }
        wait(for: [timedOut], timeout: 3)
        XCTAssertEqual(manager.activeUploadCount, 0)
        XCTAssertEqual(gateway.closed, [1])
    }

    func testDownloadsWithSameNameHaveIndependentPartials() throws {
        let gateway = TransferGateway()
        let manager = TransferManager()
        manager.gateway = gateway
        manager.downloadDirectory = try temporaryDirectory()
        let first = manager.addDownload(username: "alice", file: RemoteFileInfo(virtualPath: "\\a\\song.mp3", size: 4))!
        let second = manager.addDownload(username: "bob", file: RemoteFileInfo(virtualPath: "\\b\\song.mp3", size: 4))!
        XCTAssertEqual(gateway.messages.count, 2, "unknown addresses must still enqueue downloads")
        for (item, token, id) in [(first, UInt32(1), UInt64(1)), (second, UInt32(2), UInt64(2))] {
            _ = manager.handleTransferRequest(direction: TransferDirection.upload, token: token,
                                              file: item.virtualPath, fileSize: 4, from: item.username)
            manager.handleDownloadConnectionOpened(connectionID: id, username: item.username, token: token)
        }
        manager.handleDownloadData(connectionID: 1, data: Data([1, 2]))
        manager.handleDownloadData(connectionID: 2, data: Data([3, 4]))
        manager.cancelDownload(first)
        manager.handleDownloadData(connectionID: 2, data: Data([5, 6]))
        XCTAssertEqual(second.status, .finished)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second.localFilePath!)), Data([3, 4, 5, 6]))
    }

    func testFailedFinalMovePreservesPartial() throws {
        let manager = TransferManager()
        manager.downloadDirectory = try temporaryDirectory()
        let file = RemoteFileInfo(virtualPath: "\\folder\\" + String(repeating: "a", count: 300), size: 1)
        let item = manager.addDownload(username: "peer", file: file)!
        _ = manager.handleTransferRequest(direction: TransferDirection.upload, token: 1,
                                          file: file.virtualPath, fileSize: 1, from: "peer")
        manager.handleDownloadConnectionOpened(connectionID: 1, username: "peer", token: 1)
        manager.handleDownloadData(connectionID: 1, data: Data([42]))
        XCTAssertEqual(item.status, .failed("Could not save downloaded file"))
        XCTAssertNil(item.localFilePath)
        let partial = manager.downloadDirectory.appendingPathComponent("Partials/\(item.id.uuidString).slskpart")
        XCTAssertEqual(try Data(contentsOf: partial), Data([42]))
    }
}

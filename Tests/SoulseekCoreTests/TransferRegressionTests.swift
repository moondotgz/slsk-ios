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
    func testInitialDownloadRequestTimesOutAndCanBeRetried() throws {
        let manager = TransferManager()
        let gateway = TransferGateway()
        manager.gateway = gateway
        manager.activationTimeout = 0.01
        let item = try XCTUnwrap(manager.addDownload(username: "peer", file: RemoteFileInfo(virtualPath: "song", size: 10)))
        let timeout = expectation(description: "initial request timed out")
        manager.onChanged = { if item.status == .failed("Connection timeout") { timeout.fulfill() } }
        wait(for: [timeout], timeout: 2)
        XCTAssertEqual(item.status, .failed("Connection timeout"))
        manager.onChanged = nil
        manager.activationTimeout = 45
        manager.retryDownload(item)
        XCTAssertEqual(item.status, .queued)
        XCTAssertEqual(gateway.messages.count, 4)
        manager.serverWentOffline()
    }

    func testConfirmedRemoteQueueSurvivesInitialTimeoutButStaleRepliesDoNotChangeTransfer() throws {
        let manager = TransferManager()
        manager.gateway = TransferGateway()
        manager.activationTimeout = 0.01
        let item = try XCTUnwrap(manager.addDownload(username: "peer", file: RemoteFileInfo(virtualPath: "song", size: 10)))
        manager.handlePlaceInQueueResponse(file: "song", place: 3, from: "peer")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(item.status, .remotelyQueued)
        manager.activationTimeout = 45
        _ = manager.handleTransferRequest(direction: TransferDirection.upload, token: 1, file: "song", fileSize: 10, from: "peer")
        manager.handlePlaceInQueueResponse(file: "song", place: 99, from: "peer")
        XCTAssertEqual(item.status, .connecting)
        XCTAssertEqual(item.queuePosition, 0)
        manager.cancelDownload(item)
        manager.handlePlaceInQueueResponse(file: "song", place: 99, from: "peer")
        XCTAssertEqual(item.status, .cancelled)
    }

    func testQueueMaintenanceIncludesUnconfirmedRequestsAndDetectsUnresponsiveQueues() throws {
        let manager = TransferManager()
        let gateway = TransferGateway()
        manager.gateway = gateway
        manager.activationTimeout = 0.01
        let item = try XCTUnwrap(manager.addDownload(username: "peer", file: RemoteFileInfo(virtualPath: "song", size: 10)))
        manager.queueMaintenanceTick()
        XCTAssertEqual(gateway.messages.count, 3)
        manager.handlePlaceInQueueResponse(file: "song", place: 1, from: "peer")
        manager.queueMaintenanceTick()
        let timeout = expectation(description: "queue heartbeat timed out")
        manager.onChanged = { if item.status == .failed("Connection timeout") { timeout.fulfill() } }
        wait(for: [timeout], timeout: 2)
    }

    func testPeerFailureFailsOnlyPendingDownloadsAndAllowsLateOffer() throws {
        let manager = TransferManager()
        manager.downloadDirectory = try temporaryDirectory()
        let pending = try XCTUnwrap(manager.addDownload(username: "peer", file: RemoteFileInfo(virtualPath: "pending", size: 10)))
        let running = try XCTUnwrap(manager.addDownload(username: "peer", file: RemoteFileInfo(virtualPath: "running", size: 10)))
        _ = manager.handleTransferRequest(direction: TransferDirection.upload, token: 1, file: "running", fileSize: 10, from: "peer")
        manager.handleDownloadConnectionOpened(connectionID: 1, username: "peer", token: 1)
        manager.handlePeerConnectionFailed("peer")
        XCTAssertEqual(pending.status, .failed("Peer connection failed"))
        XCTAssertEqual(running.status, .transferring)
        let reply = manager.handleTransferRequest(direction: TransferDirection.upload, token: 2, file: "pending", fileSize: 10, from: "peer")
        XCTAssertEqual(reply, PeerOut.transferResponse(token: 2, allowed: true))
        manager.serverWentOffline()
    }

    func testInterruptedDownloadsPersistWithResumeIdentity() throws {
        let storage = Storage(baseURL: try temporaryDirectory())
        let manager = TransferManager()
        manager.configure(storage: storage, gateway: nil, shares: nil)
        let item = try XCTUnwrap(manager.addDownload(username: "peer", file: RemoteFileInfo(virtualPath: "song", size: 10)))
        item.status = .transferring
        item.currentOffset = 4
        manager.persist()
        let restored = TransferManager()
        restored.configure(storage: storage, gateway: nil, shares: nil)
        let saved = try XCTUnwrap(restored.downloads.first)
        XCTAssertEqual(saved.id, item.id)
        XCTAssertEqual(saved.currentOffset, 4)
        XCTAssertEqual(saved.status, .paused)
        manager.serverWentOffline()
        restored.serverWentOffline()
    }

    func testLegacyRequestForMissingFileIsDeniedInsteadOfQueued() {
        let manager = TransferManager()
        XCTAssertEqual(manager.handleLegacyDownloadRequest(token: 1, file: "missing", from: "peer"),
                       PeerOut.transferResponse(token: 1, allowed: false, reason: TransferRejectReason.fileNotShared))
        XCTAssertTrue(manager.uploads.isEmpty)
    }

    func testUploadFailedDoesNotRequeueForever() throws {
        let manager = TransferManager()
        let gateway = TransferGateway()
        manager.gateway = gateway
        let item = try XCTUnwrap(manager.addDownload(username: "peer", file: RemoteFileInfo(virtualPath: "song", size: 1)))
        manager.handleUploadFailed(file: "song", from: "peer")
        manager.handleUploadFailed(file: "song", from: "peer")
        XCTAssertEqual(item.status, .failed("Remote upload failed"))
        XCTAssertEqual(gateway.messages.count, 2)
    }

    func testUploadQueuePositionExcludesFinishedHistory() throws {
        let gateway = TransferGateway()
        let (manager, first, token) = try upload(Data([1]), gateway: gateway)
        manager.uploadSlots = 1
        manager.handleTransferResponse(token: token, allowed: false, reason: TransferRejectReason.complete, from: "peer")
        _ = manager.handleQueueUpload(file: first.virtualPath, from: "second")
        _ = manager.handleQueueUpload(file: first.virtualPath, from: "third")
        var response = MessageBuffer(try XCTUnwrap(manager.handlePlaceInQueueRequest(file: first.virtualPath, from: "third")))
        _ = try response.readUInt32()
        XCTAssertEqual(try response.readUInt32(), PeerCode.placeInQueueResponse)
        _ = try response.readString()
        XCTAssertEqual(try response.readUInt32(), 1)
        manager.serverWentOffline()
    }

    func testDownloadLimitDefersExtraOffers() throws {
        let manager = TransferManager()
        manager.maxDownloadConnections = 1
        for name in ["first", "second"] {
            _ = manager.addDownload(username: "peer", file: RemoteFileInfo(virtualPath: name, size: 10))
        }
        XCTAssertEqual(manager.handleTransferRequest(direction: TransferDirection.upload, token: 1, file: "first", fileSize: 10, from: "peer"),
                       PeerOut.transferResponse(token: 1, allowed: true))
        XCTAssertEqual(manager.handleTransferRequest(direction: TransferDirection.upload, token: 2, file: "second", fileSize: 10, from: "peer"),
                       PeerOut.transferResponse(token: 2, allowed: false, reason: TransferRejectReason.queued))
        manager.serverWentOffline()
    }

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
        XCTAssertEqual(gateway.messages.count, 4, "each download sends a queue request and position request")
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

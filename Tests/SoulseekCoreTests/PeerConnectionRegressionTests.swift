import Foundation
import XCTest
@testable import SoulseekCore

final class PeerConnectionRegressionTests: XCTestCase {
    func testAddressUpdatesDoNotDialUnrequestedPeers() {
        let factory = MockTransportFactory()
        let manager = PeerConnectionManager(factory: factory)
        manager.localUsername = "tester"
        defer { manager.closeAll() }
        for index in 0..<1000 {
            manager.setPeerAddress("peer\(index)", host: "127.0.0.1", port: 5000)
        }
        XCTAssertEqual(factory.peerStreams.count, 0)
    }

    func testSearchFloodIsBoundedAndLeavesRoomForDownloads() {
        let factory = MockTransportFactory()
        let manager = PeerConnectionManager(factory: factory)
        manager.localUsername = "tester"
        defer { manager.closeAll() }
        var requested: [String] = []
        manager.addressRequestHandler = { requested.append($0) }
        for index in 0..<1000 {
            manager.sendSearchResponse("searcher\(index)", Data([1]))
        }
        XCTAssertEqual(requested.count, 16)
        for username in requested {
            manager.setPeerAddress(username, host: "127.0.0.1", port: 5000)
        }
        XCTAssertEqual(manager.activeConnectionCount, 16)
        manager.sendToPeer("uploader", PeerOut.queueUpload("song"))
        manager.setPeerAddress("uploader", host: "127.0.0.1", port: 5000)
        XCTAssertEqual(manager.activeConnectionCount, 17)
    }

    func testIdlePeersExpireAndCanReconnect() {
        let factory = MockTransportFactory()
        let manager = PeerConnectionManager(factory: factory)
        manager.localUsername = "tester"
        defer { manager.closeAll() }
        manager.sendToPeer("peer", PeerOut.queueUpload("song"))
        manager.setPeerAddress("peer", host: "127.0.0.1", port: 5000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(manager.activeConnectionCount, 1)
        manager.maintainConnections(now: Date().addingTimeInterval(61))
        XCTAssertEqual(manager.activeConnectionCount, 0)
        manager.sendToPeer("peer", PeerOut.queueUpload("other"))
        XCTAssertEqual(manager.activeConnectionCount, 1)
    }

    func testParentCandidatesAreDeduplicatedAndUnclassifiedSocketsAreBounded() {
        let factory = MockTransportFactory()
        let manager = PeerConnectionManager(factory: factory)
        manager.localUsername = "tester"
        defer { manager.closeAll() }
        for _ in 0..<100 {
            manager.connectToParentCandidate(username: "parent", host: "127.0.0.1", port: 5000)
        }
        XCTAssertEqual(factory.peerStreams.count, 1)
        for _ in 0..<100 { _ = factory.listener.accept() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertLessThanOrEqual(manager.activeConnectionCount, 48)
        manager.maintainConnections(now: Date().addingTimeInterval(31))
        XCTAssertEqual(manager.activeConnectionCount, 1)
    }

    func testFileConnectionsHaveReservedCapacityAndActiveFilesAreNotIdlePeerExpired() {
        let factory = MockTransportFactory()
        let manager = PeerConnectionManager(factory: factory)
        manager.localUsername = "tester"
        defer { manager.closeAll() }
        for _ in 0..<60 { _ = factory.listener.accept() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(manager.activeConnectionCount, 48)
        for index in 0..<100 {
            manager.openDownloadConnection(username: "uploader\(index)", host: "127.0.0.1", port: 5000,
                                           token: UInt32(index))
        }
        XCTAssertEqual(manager.activeConnectionCount, 64)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        var token = MessageBuffer()
        token.writeUInt32(123)
        factory.peerStreams[0].inject(token.data)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        manager.maintainConnections(now: Date().addingTimeInterval(61))
        XCTAssertEqual(manager.activeConnectionCount, 1)
    }

    func testIncomingIndirectPeerConnectionIsReusedForReplies() {
        let factory = MockTransportFactory()
        let manager = PeerConnectionManager(factory: factory)
        manager.localUsername = "tester"
        defer { manager.closeAll() }
        manager.sendToPeer("peer", PeerOut.queueUpload("song"))
        manager.handleIncomingIndirectInvitation(username: "peer", type: ConnectionType.peer,
                                                host: "127.0.0.1", port: 5000, token: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        manager.sendToPeer("peer", PeerOut.transferResponse(token: 2, allowed: true))
        XCTAssertEqual(factory.peerStreams.count, 1)
        XCTAssertEqual(factory.peerStreams[0].sentFrames.last, PeerOut.transferResponse(token: 2, allowed: true))
    }

    func testCantConnectResetsSessionSoRetryCanFallBackAgain() throws {
        let factory = MockTransportFactory()
        let manager = PeerConnectionManager(factory: factory)
        manager.localUsername = "tester"
        defer { manager.closeAll() }
        var tokens: [UInt32] = []
        manager.indirectRequestHandler = { _, _, token in tokens.append(token) }
        manager.sendToPeer("peer", PeerOut.queueUpload("song"))
        manager.setPeerAddress("peer", host: "127.0.0.1", port: 5000)
        manager.byteStream(factory.peerStreams[0], didCloseWith: SlskError.notConnected)
        manager.handleCantConnect(token: try XCTUnwrap(tokens.first))
        manager.sendToPeer("peer", PeerOut.queueUpload("song"))
        XCTAssertEqual(factory.peerStreams.count, 2)
        manager.byteStream(factory.peerStreams[1], didCloseWith: SlskError.notConnected)
        XCTAssertEqual(tokens.count, 2)
    }

    func testFailedDirectPeerConnectionFallsBackAndFlushesPendingMessages() throws {
        let factory = MockTransportFactory()
        let manager = PeerConnectionManager(factory: factory)
        manager.localUsername = "tester"
        let message = PeerOut.queueUpload("\\folder\\song.mp3")
        manager.sendToPeer("peer", message)
        var invitation: (String, String, UInt32)?
        manager.indirectRequestHandler = { invitation = ($0, $1, $2) }
        manager.setPeerAddress("peer", host: "127.0.0.1", port: 5000)
        let direct = factory.peerStreams[0]
        manager.byteStream(direct, didCloseWith: SlskError.notConnected)
        XCTAssertEqual(invitation?.0, "peer")
        XCTAssertEqual(invitation?.1, ConnectionType.peer)
        let token = try XCTUnwrap(invitation?.2)
        let incoming = factory.listener.accept()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        incoming.inject(PeerInitOut.pierceFirewall(token: token))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(incoming.sentFrames, [message])
        manager.closeAll()
    }

    func testFailedDirectUploadConnectionInvitesIndirectFileConnection() {
        let factory = MockTransportFactory()
        let manager = PeerConnectionManager(factory: factory)
        manager.localUsername = "tester"
        manager.setPeerAddress("peer", host: "127.0.0.1", port: 5000)
        var invitations: [(String, String, UInt32)] = []
        manager.indirectRequestHandler = { invitations.append(($0, $1, $2)) }
        _ = manager.openUploadConnection(username: "peer", token: 123)
        let fileStream = factory.peerStreams.last!
        manager.byteStream(fileStream, didCloseWith: SlskError.notConnected)
        XCTAssertEqual(invitations.count, 1)
        XCTAssertEqual(invitations.first?.0, "peer")
        XCTAssertEqual(invitations.first?.1, ConnectionType.file)
        XCTAssertEqual(invitations.first?.2, 123)
        manager.closeAll()
    }
}

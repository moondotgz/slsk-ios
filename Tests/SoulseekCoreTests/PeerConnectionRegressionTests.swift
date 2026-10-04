import Foundation
import XCTest
@testable import SoulseekCore

final class PeerConnectionRegressionTests: XCTestCase {
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

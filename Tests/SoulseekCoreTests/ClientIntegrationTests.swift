import Foundation
import XCTest
@testable import SoulseekCore

/// In-memory ByteStream pair. `start()` marks the stream open; data sent by
/// the client is recorded and optionally piped to a paired stream.
final class MockStream: ByteStream {
    let identifier: UInt64 = MockStream.nextID()
    weak var delegate: (any ByteStreamDelegate)?
    var sentFrames: [Data] = []
    var sentRaw: [Data] = []
    var isOpen = false
    /// When set, every send is forwarded to this stream's delegate.
    weak var pipeTo: MockStream?

    private static var counter: UInt64 = 0
    private static let lock = NSLock()
    private static func nextID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }

    func start(host: String?, port: UInt16, initialBytes: Data?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isOpen = true
            if let initialBytes {
                self.send(initialBytes)
            }
            self.delegate?.byteStreamDidOpen(self)
        }
    }

    func send(_ data: Data) {
        sentFrames.append(data)
        if let peer = pipeTo {
            DispatchQueue.main.async {
                peer.delegate?.byteStream(peer, didReceive: data)
            }
        }
    }

    func send(_ data: Data, completion: @escaping ((any Error)?) -> Void) {
        send(data)
        DispatchQueue.main.async { completion(nil) }
    }

    func close() {
        isOpen = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.byteStream(self, didCloseWith: nil)
        }
    }

    /// Deliver bytes as if the remote side sent them.
    func inject(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.byteStream(self, didReceive: data)
        }
    }
}

final class MockListener: ListenerService {
    weak var delegate: (any ListenerServiceDelegate)?
    var boundPort: UInt16 = 2234
    var onPortBound: ((UInt16) -> Void)?
    var acceptedStreams: [MockStream] = []

    func start(requestedPort: UInt16) {
        boundPort = requestedPort
        onPortBound?(requestedPort)
    }

    func stop() {}

    /// Simulate a remote peer connecting to our listener; returns the stream
    /// the client will talk on.
    @discardableResult
    func accept() -> MockStream {
        let stream = MockStream()
        acceptedStreams.append(stream)
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.listener(self!, didAccept: stream)
        }
        return stream
    }
}

final class MockTransportFactory: TransportFactory {
    let listener = MockListener()
    var serverStreams: [MockStream] = []
    var peerStreams: [MockStream] = []

    func makeServerStream() -> any ByteStream {
        let stream = MockStream()
        serverStreams.append(stream)
        return stream
    }

    func makePeerStream() -> any ByteStream {
        let stream = MockStream()
        peerStreams.append(stream)
        return stream
    }

    func makeListener() -> any ListenerService {
        listener
    }
}

enum TestFrames {
    static func server(_ code: UInt32, _ payload: [UInt8]) -> Data {
        Frame.server(code: code, payload: payload)
    }

    static func loginSuccess(ip: [UInt8] = [1, 2, 3, 4]) -> Data {
        var b = MessageBuffer()
        b.writeBool(true)
        b.writeString("Welcome!")
        b.writeBytes(ip) // reversed-octet IP
        b.writeString("checksum")
        b.writeBool(false)
        return Frame.server(code: ServerCode.login, payload: b.bytes)
    }

    static func peerAddress(username: String, ip: [UInt8], port: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        b.writeBytes(ip)
        b.writeUInt32(port)
        b.writeUInt32(0) // obfuscation type
        b.writeUInt16(0) // obfuscated port
        return Frame.server(code: ServerCode.getPeerAddress, payload: b.bytes)
    }
}

final class ClientIntegrationTests: XCTestCase {
    private func pump(_ seconds: Double = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeClient(factory: MockTransportFactory) -> (SoulseekClient, MockStream, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slsk-test-\(UUID().uuidString)", isDirectory: true)
        let storage = Storage(baseURL: dir)
        var config = ClientConfiguration()
        config.username = "tester"
        config.password = "secret"
        let client = SoulseekClient(factory: factory, storage: storage, config: config)
        client.start()
        client.connect()
        pump()
        return (client, factory.serverStreams.first!, dir)
    }

    private func login(_ client: SoulseekClient, server: MockStream) {
        server.inject(TestFrames.loginSuccess())
        pump()
        XCTAssertEqual(client.connectionState, .loggedIn)
        XCTAssertEqual(client.loggedInUsername, "tester")
    }

    func testLoginSendsPostLoginSequence() {
        let factory = MockTransportFactory()
        let (client, server, _) = makeClient(factory: factory)
        XCTAssertEqual(factory.serverStreams.count, 1)
        XCTAssertTrue(server.isOpen)

        // First outgoing frame is the login packet.
        XCTAssertEqual(server.sentFrames.count, 1)
        var login = MessageBuffer(server.sentFrames[0])
        XCTAssertEqual(try? login.readUInt32(), UInt32(server.sentFrames[0].count - 4))
        XCTAssertEqual(try? login.readUInt32(), ServerCode.login)
        XCTAssertEqual(try? login.readString(), "tester")
        XCTAssertEqual(try? login.readString(), "secret")

        server.inject(TestFrames.loginSuccess())
        pump()
        XCTAssertEqual(client.connectionState, .loggedIn)

        // Post-login: setWaitPort, checkPrivileges, haveNoParent, branchLevel, branchRoot, roomList
        var codes: [UInt32] = []
        for frame in server.sentFrames.dropFirst() {
            var buffer = MessageBuffer(frame)
            if let length = try? buffer.readUInt32(), length > 0, let code = try? buffer.readUInt32() {
                codes.append(code)
            }
        }
        XCTAssertTrue(codes.contains(ServerCode.setWaitPort))
        XCTAssertTrue(codes.contains(ServerCode.checkPrivileges))
        XCTAssertTrue(codes.contains(ServerCode.haveNoParent))
        XCTAssertTrue(codes.contains(ServerCode.branchLevel))
        XCTAssertTrue(codes.contains(ServerCode.branchRoot))
        XCTAssertTrue(codes.contains(ServerCode.roomList))
    }

    func testPeerConnectionFailureUpdatesQueuedDownload() throws {
        let factory = MockTransportFactory()
        let (client, server, directory) = makeClient(factory: factory)
        defer { client.disconnect(); try? FileManager.default.removeItem(at: directory) }
        login(client, server: server)
        let item = try XCTUnwrap(client.transfers.addDownload(username: "offline", file: RemoteFileInfo(virtualPath: "song", size: 10)))
        server.inject(TestFrames.peerAddress(username: "offline", ip: [0, 0, 0, 0], port: 0))
        pump()
        XCTAssertEqual(item.status, .failed("Peer connection failed"))
    }

    func testRecommendationsInterestsAndGlobalFeedState() throws {
        let factory = MockTransportFactory()
        let (client, server, directory) = makeClient(factory: factory)
        defer { client.disconnect(); try? FileManager.default.removeItem(at: directory) }
        login(client, server: server)
        var recommendations = MessageBuffer()
        recommendations.writeUInt32(1)
        recommendations.writeString("music")
        recommendations.writeInt32(5)
        recommendations.writeUInt32(0)
        server.inject(Frame.server(code: ServerCode.recommendations, payload: recommendations.bytes))
        var interests = MessageBuffer()
        interests.writeString("peer")
        interests.writeUInt32(1)
        interests.writeString("rock")
        interests.writeUInt32(1)
        interests.writeString("spam")
        server.inject(Frame.server(code: ServerCode.userInterests, payload: interests.bytes))
        pump()
        XCTAssertEqual(client.recommendations.first?.item, "music")
        XCTAssertEqual(client.userInterests["peer"]?.likes, ["rock"])
        XCTAssertEqual(client.userInterests["peer"]?.hates, ["spam"])
        var empty = MessageBuffer()
        empty.writeUInt32(0)
        empty.writeUInt32(0)
        server.inject(Frame.server(code: ServerCode.globalRecommendations, payload: empty.bytes))
        pump()
        XCTAssertTrue(client.recommendations.isEmpty, "shorter responses must replace older lists")
        client.joinGlobalRoomFeed()
        XCTAssertTrue(client.isGlobalRoomFeedEnabled, "feed is enabled even before any messages arrive")
        client.leaveGlobalRoomFeed()
        XCTAssertFalse(client.isGlobalRoomFeedEnabled)
    }

    func testEmbeddedSearchRespondsToSearcherAndForwardsFramedMessagesOnlyToChildren() throws {
        let factory = MockTransportFactory()
        let (client, server, directory) = makeClient(factory: factory)
        defer { client.disconnect(); try? FileManager.default.removeItem(at: directory) }
        login(client, server: server)
        let root = directory.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("music.mp3"))
        client.setSharedDirectories([root])
        pump(0.1)
        client.distributed.parentMinSpeed = 1
        client.distributed.parentSpeedRatio = 1
        client.distributed.uploadSpeed = 100
        let child = factory.listener.accept()
        pump(0.02)
        child.inject(PeerInitOut.peerInit(username: "child", type: ConnectionType.distributed))
        pump(0.02)
        var search = MessageBuffer()
        search.writeUInt32(49)
        search.writeString("searcher")
        search.writeUInt32(7)
        search.writeString("music")
        var embedded = MessageBuffer()
        embedded.writeByte(DistribCode.distribSearch.rawValue)
        embedded.writeBytes(search.bytes)
        server.inject(Frame.server(code: ServerCode.embeddedMessage, payload: embedded.bytes))
        pump(0.02)
        XCTAssertEqual(child.sentFrames.last, Frame.distributed(code: DistribCode.distribSearch.rawValue, payload: search.bytes))
        server.inject(TestFrames.peerAddress(username: "searcher", ip: [1, 0, 0, 127], port: 5000))
        pump(0.02)
        let peer = try XCTUnwrap(factory.peerStreams.last)
        var response = MessageBuffer(try XCTUnwrap(peer.sentFrames.last))
        _ = try response.readUInt32()
        XCTAssertEqual(try response.readUInt32(), PeerCode.fileSearchResponse)
    }

    func testCompressedSearchResultsOverDirectAndIndirectPeerConnections() throws {
        for indirect in [false, true] {
            let factory = MockTransportFactory()
            let (client, server, directory) = makeClient(factory: factory)
            defer { client.disconnect(); try? FileManager.default.removeItem(at: directory) }
            login(client, server: server)
            client.startSearch("karma police")
            let session = try XCTUnwrap(client.search.activeSessions.first)
            var request = MessageBuffer(try XCTUnwrap(server.sentFrames.last))
            _ = try request.readUInt32()
            XCTAssertEqual(try request.readUInt32(), ServerCode.fileSearch)
            XCTAssertEqual(try request.readUInt32(), session.token)
            XCTAssertEqual(try request.readString(), "karma police")

            let peer: MockStream
            var initial = Data()
            if indirect {
                var invitation = MessageBuffer()
                invitation.writeString("searcher")
                invitation.writeString(ConnectionType.peer)
                invitation.writeIPAddress("127.0.0.1")
                invitation.writeUInt32(5000)
                invitation.writeUInt32(123)
                server.inject(Frame.server(code: ServerCode.connectToPeer, payload: invitation.bytes))
                pump()
                peer = try XCTUnwrap(factory.peerStreams.last)
                XCTAssertEqual(peer.sentFrames.first, PeerInitOut.pierceFirewall(token: 123))
            } else {
                peer = factory.listener.accept()
                pump()
                initial = PeerInitOut.peerInit(username: "searcher", type: ConnectionType.peer)
            }

            let file = RemoteFileInfo(virtualPath: "\\music\\Karma Police.mp3", size: 1234567,
                                      bitrate: 320, duration: 240)
            var payload = MessageBuffer()
            payload.writeString("searcher")
            payload.writeUInt32(session.token)
            payload.writeUInt32(1)
            FileListCodec.packFileInfo(file, into: &payload)
            payload.writeBool(true)
            payload.writeUInt32(500000)
            payload.writeUInt32(2)
            payload.writeUInt32(0)
            let compressed = try Zlib.compress(payload.data)
            let packet = initial + Frame.peer(code: PeerCode.fileSearchResponse, payload: [UInt8](compressed))
            let revision = client.searchRevision
            for offset in stride(from: 0, to: packet.count, by: 7) {
                peer.inject(Data(packet[offset..<min(offset + 7, packet.count)]))
            }
            pump()
            XCTAssertEqual(session.hits.count, 1)
            XCTAssertEqual(session.hits.first?.file, file)
            XCTAssertEqual(session.hits.first?.username, "searcher")
            XCTAssertEqual(session.hits.first?.freeUploadSlot, true)
            XCTAssertEqual(session.hits.first?.uploadSpeed, 500000)
            XCTAssertEqual(session.hits.first?.queueLength, 2)
            XCTAssertGreaterThan(client.searchRevision, revision)
        }
    }

    func testCompressedBrowseAndFolderResponsesExcludePeerMessageCode() throws {
        let factory = MockTransportFactory()
        let (client, server, directory) = makeClient(factory: factory)
        defer { client.disconnect(); try? FileManager.default.removeItem(at: directory) }
        login(client, server: server)
        let peer = factory.listener.accept()
        pump()
        peer.inject(PeerInitOut.peerInit(username: "sharer", type: ConnectionType.peer))
        pump()
        client.browseUser("sharer")
        let file = RemoteFileInfo(virtualPath: "\\music\\song.mp3", size: 12345, bitrate: 320)
        var browse = MessageBuffer()
        browse.writeUInt32(1)
        browse.writeString(file.folder)
        browse.writeUInt32(1)
        FileListCodec.packFileInfo(file, into: &browse, includeFolder: false)
        browse.writeUInt32(0)
        peer.inject(Frame.peer(code: PeerCode.sharedFileListResponse,
                               payload: [UInt8](try Zlib.compress(browse.data))))
        pump()
        let session = try XCTUnwrap(client.browseSession(for: "sharer"))
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.folders[file.folder], [file])

        var folderResult: [String: [RemoteFileInfo]]?
        client.requestFolderContents(username: "sharer", folder: file.folder) { folderResult = $0 }
        var request = MessageBuffer(try XCTUnwrap(peer.sentFrames.last))
        _ = try request.readUInt32()
        XCTAssertEqual(try request.readUInt32(), PeerCode.folderContentsRequest)
        let token = try request.readUInt32()
        var folder = MessageBuffer()
        folder.writeUInt32(token)
        folder.writeString(file.folder)
        folder.writeUInt32(1)
        folder.writeString(file.folder)
        folder.writeUInt32(1)
        FileListCodec.packFileInfo(file, into: &folder, includeFolder: false)
        peer.inject(Frame.peer(code: PeerCode.folderContentsResponse,
                               payload: [UInt8](try Zlib.compress(folder.data))))
        pump()
        XCTAssertEqual(folderResult?[file.folder], [file])
    }

    func testServerSearchTriggersShareResponseOverPeerConnection() {
        let factory = MockTransportFactory()
        let (client, server, _) = makeClient(factory: factory)
        login(client, server: server)

        // Share one folder with a matching file.
        let shareRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slsk-share-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: shareRoot.appendingPathComponent("Radiohead"),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: shareRoot.appendingPathComponent("Radiohead/Karma Police.mp3").path,
                                       contents: Data(repeating: 0, count: 128))
        client.setSharedDirectories([shareRoot])
        pump(0.5)
        XCTAssertEqual(client.shares.sharedFileCount, 1)

        // Server delivers a search request for "karma police".
        var searchPayload = MessageBuffer()
        searchPayload.writeString("searcher")
        searchPayload.writeUInt32(777)
        searchPayload.writeString("karma police")
        server.inject(Frame.server(code: ServerCode.fileSearch, payload: searchPayload.bytes))
        pump()

        // Client must ask the server for the searcher's address.
        let askedAddress = server.sentFrames.contains { frame in
            var buffer = MessageBuffer(frame)
            guard let _ = try? buffer.readUInt32(), let code = try? buffer.readUInt32() else { return false }
            guard code == ServerCode.getPeerAddress else { return false }
            return (try? buffer.readString()) == "searcher"
        }
        XCTAssertTrue(askedAddress, "client did not request peer address for searcher")

        // Reply with an address; client should open a 'P' connection.
        server.inject(TestFrames.peerAddress(username: "searcher", ip: [9, 9, 9, 9], port: 5000))
        pump()
        XCTAssertEqual(factory.peerStreams.count, 1)

        let peer = factory.peerStreams[0]
        // Initial bytes: PeerInit frame for the searcher.
        XCTAssertEqual(peer.sentFrames.count, 2)
        var initFrame = MessageBuffer(peer.sentFrames[0])
        XCTAssertEqual(try? initFrame.readUInt32(), UInt32(peer.sentFrames[0].count - 4))
        XCTAssertEqual(try? initFrame.readByte(), PeerInitCode.peerInit.rawValue)
        XCTAssertEqual(try? initFrame.readString(), "tester")
        XCTAssertEqual(try? initFrame.readString(), "P")

        guard peer.sentFrames.count >= 2 else { return }
        var response = MessageBuffer(peer.sentFrames[1])
        _ = try? response.readUInt32()
        XCTAssertEqual(try? response.readUInt32(), PeerCode.fileSearchResponse)
    }

    func testIncomingQueueUploadProducesDenialForUnsharedFile() {
        let factory = MockTransportFactory()
        let (client, server, _) = makeClient(factory: factory)
        login(client, server: server)

        // A peer connects through the listener with PeerInit 'P'.
        let incoming = factory.listener.accept()
        pump()
        var initPayload = MessageBuffer()
        initPayload.writeString("downloader")
        initPayload.writeString("P")
        initPayload.writeUInt32(0)
        incoming.inject(Frame.initMessage(code: PeerInitCode.peerInit.rawValue, payload: initPayload.bytes))
        pump()

        // They request a file we do not share.
        var queue = MessageBuffer()
        queue.writeString("\\nobody\\secret.mp3")
        incoming.inject(Frame.peer(code: PeerCode.queueUpload, payload: queue.bytes))
        pump()

        // Client must reply with an UploadDenied on the same stream.
        let denial = incoming.sentFrames.first { frame in
            var buffer = MessageBuffer(frame)
            guard let _ = try? buffer.readUInt32(), let code = try? buffer.readUInt32() else { return false }
            return code == PeerCode.uploadDenied
        }
        XCTAssertNotNil(denial, "expected UploadDenied reply")
        if let denial {
            var buffer = MessageBuffer(denial.dropFirst(8))
            XCTAssertEqual(try? buffer.readString(), "\\nobody\\secret.mp3")
            XCTAssertEqual(try? buffer.readString(), TransferRejectReason.fileNotShared)
        }
    }

    func testAcceptedFileHandshakeAndRawDataAcrossReadBoundaries() throws {
        for chunkSize in [1, 7, 1024] {
            let factory = MockTransportFactory()
            let (client, server, storageURL) = makeClient(factory: factory)
            login(client, server: server)
            let downloadURL = storageURL.appendingPathComponent("Downloads")
            client.transfers.downloadDirectory = downloadURL
            defer { client.disconnect(); try? FileManager.default.removeItem(at: storageURL) }
            let file = RemoteFileInfo(virtualPath: "\\folder\\song.mp3", size: 4)
            let item = client.transfers.addDownload(username: "uploader", file: file)!
            _ = client.transfers.handleTransferRequest(direction: TransferDirection.upload, token: 777,
                                                       file: file.virtualPath, fileSize: 4, from: "uploader")
            let incoming = factory.listener.accept()
            pump()
            XCTAssertTrue(incoming.isOpen, "accepted streams must be started")
            var token = MessageBuffer()
            token.writeUInt32(777)
            let packet = PeerInitOut.peerInit(username: "uploader", type: ConnectionType.file)
                + token.data + Data([0, 0, 0, 0])
            for offset in stride(from: 0, to: packet.count, by: chunkSize) {
                incoming.inject(Data(packet[offset..<min(offset + chunkSize, packet.count)]))
            }
            pump()
            XCTAssertEqual(item.status, .finished)
            if let path = item.localFilePath {
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([0, 0, 0, 0]))
            } else { XCTFail("download has no final path") }
        }
    }
}

extension MessageBuffer {
    /// Read all remaining bytes as Data.
    mutating func readRemainingAsData() -> Data {
        Data(readRemaining())
    }
}

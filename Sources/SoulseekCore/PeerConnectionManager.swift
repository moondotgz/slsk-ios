import Foundation

public enum FileConnectionRole {
    /// We are uploading: send FileTransferInit (raw uint32), await offset, push data.
    case upload(token: UInt32)
    /// We are downloading: await FileTransferInit (raw uint32), push offset, receive data.
    case download
}

public protocol PeerConnectionManagerDelegate: AnyObject {
    func peerManager(_ manager: PeerConnectionManager, didReceivePeerMessageCode code: UInt32,
                     body: MessageBuffer, from username: String)
    func peerManager(_ manager: PeerConnectionManager, didReceiveDistribCode code: UInt8,
                     body: MessageBuffer, from username: String, connectionID: UInt64)
    func peerManager(_ manager: PeerConnectionManager, didOpenDownloadConnection id: UInt64,
                     username: String, token: UInt32)
    func peerManager(_ manager: PeerConnectionManager, didOpenUploadConnection id: UInt64,
                     username: String, token: UInt32)
    func peerManager(_ manager: PeerConnectionManager, didReceiveFileData id: UInt64, data: Data)
    func peerManager(_ manager: PeerConnectionManager, didReceiveUploadOffset id: UInt64, offset: UInt64)
    func peerManager(_ manager: PeerConnectionManager, didCloseFileConnection id: UInt64, error: (any Error)?)
    func peerManager(_ manager: PeerConnectionManager, didFailPeerConnection username: String)
    func peerManager(_ manager: PeerConnectionManager, distributedConnectionClosed username: String)
    func peerManager(_ manager: PeerConnectionManager, didAcceptChildConnection id: UInt64, username: String)
}

/// Gateway used by the other managers to reach peers without touching sockets.
public protocol PeerGateway: AnyObject {
    func sendToPeer(_ username: String, _ data: Data)
    func requestPeerAddress(_ username: String)
    func peerAddress(for username: String) -> (host: String, port: UInt16)?
    func setPeerAddress(_ username: String, host: String, port: UInt16)
    func isUserOnline(_ username: String) -> Bool
    func requestIndirectConnection(_ username: String, type: String, token: UInt32)
    func sendCantConnectToPeer(token: UInt32, username: String)
    @discardableResult
    func openUploadConnection(username: String, token: UInt32) -> UInt64?
    func sendFileData(_ connectionID: UInt64, _ data: Data)
    func sendFileOffset(_ connectionID: UInt64, _ offset: UInt64)
    func closeFileConnection(_ connectionID: UInt64)
    func sendToDistributedChildren(_ data: Data)
    func connectToParentCandidate(username: String, host: String, port: UInt16)
    func rejectParentCandidates()
}

/// Manages every peer connection ('P' chat/transfer, 'D' distributed, 'F' file),
/// including direct connects, indirect ConnectToPeer piercing and message
/// routing. Mirrors Nicotine+'s connection layer (slskproto.py).
public final class PeerConnectionManager: PeerGateway {
    public weak var delegate: (any PeerConnectionManagerDelegate)?
    /// Our username for PeerInit frames; nil while logged out.
    public var localUsername: String?
    public var addressRequestHandler: ((String) -> Void)?
    public var indirectRequestHandler: ((_ username: String, _ type: String, _ token: UInt32) -> Void)?
    public var cantConnectHandler: ((_ token: UInt32, _ username: String) -> Void)?
    public var listenErrorHandler: ((any Error) -> Void)?

    public let factory: any TransportFactory
    public let listener: any ListenerService

    private let tokens = TokenGenerator()
    private var nextStreamID: UInt64 = 0

    private final class PeerSession {
        var username: String
        var address: (host: String, port: UInt16)?
        var addressRequested = false
        var connection: PeerConnection?
        var pendingMessages: [Data] = []
        var isConnecting = false
        var usedIndirect = false

        init(username: String) {
            self.username = username
        }
    }

    enum FileState {
        /// Listener-accepted connection from an unknown peer: expect a PeerInit
        /// frame (uploader connecting directly), then the raw token.
        case awaitingInitFrame
        /// Downloader side: await 4-byte FileTransferInit token.
        case awaitingToken
        case receivingData
        /// Uploader side: token sent, await 8-byte FileOffset.
        case awaitingOffset
        case uploading
    }

    final class PeerConnection {
        let id: UInt64
        let stream: any ByteStream
        var kind: String // P, D, F or "?" while undetermined
        var username: String?
        var assembler = FrameAssembler()
        var fileState: FileState?
        var rawBuffer = Data()
        var isOpen = false

        init(id: UInt64, stream: any ByteStream, kind: String) {
            self.id = id
            self.stream = stream
            self.kind = kind
        }
    }

    private var connections: [UInt64: PeerConnection] = [:]
    private var sessions: [String: PeerSession] = [:]
    /// PierceFirewall tokens for connections we invited via ConnectToPeer.
    private var pierceTokens: [UInt32: (username: String, kind: String)] = [:]
    private var indirectTimers: [UInt32: Timer] = [:]

    public init(factory: any TransportFactory) {
        self.factory = factory
        listener = factory.makeListener()
        listener.delegate = self
        listener.onPortBound = { [weak self] port in
            guard let self else { return }
            self.boundPort = port
            self.portChangedHandler?(port)
        }
    }

    // MARK: - Listener

    public private(set) var boundPort: UInt16 = 0
    /// Fired whenever the listener (re)binds, including ephemeral fallback.
    public var portChangedHandler: ((UInt16) -> Void)?

    public func startListening(port: UInt16) {
        listener.start(requestedPort: port)
    }

    public func stopListening() {
        listener.stop()
    }

    // MARK: - PeerGateway

    public func requestPeerAddress(_ username: String) {
        addressRequestHandler?(username)
    }

    public func peerAddress(for username: String) -> (host: String, port: UInt16)? {
        sessions[username]?.address
    }

    public func setPeerAddress(_ username: String, host: String, port: UInt16) {
        let session = session(for: username)
        session.address = port > 0 ? (host, port) : nil
        session.addressRequested = false

        if session.address != nil {
            attemptDirectConnection(session)
        } else if !session.pendingMessages.isEmpty {
            session.pendingMessages.removeAll()
            delegate?.peerManager(self, didFailPeerConnection: username)
        }
    }

    public func isUserOnline(_ username: String) -> Bool {
        sessions[username]?.address != nil
    }

    public func sendToPeer(_ username: String, _ data: Data) {
        guard localUsername != nil else { return }
        let session = session(for: username)

        if let connection = session.connection, connection.isOpen, connection.kind == ConnectionType.peer {
            connection.stream.send(data)
            return
        }

        session.pendingMessages.append(data)
        guard !session.isConnecting else { return }

        if session.address != nil {
            attemptDirectConnection(session)
        } else if !session.addressRequested {
            session.addressRequested = true
            requestPeerAddress(username)
        }
    }

    public func requestIndirectConnection(_ username: String, type: String, token: UInt32) {
        indirectRequestHandler?(username, type, token)
    }

    public func sendCantConnectToPeer(token: UInt32, username: String) {
        cantConnectHandler?(token, username)
    }

    // MARK: - File connections

    @discardableResult
    public func openUploadConnection(username: String, token: UInt32) -> UInt64? {
        let session = session(for: username)

        if let address = session.address {
            let connection = makeFileConnection(username: username)
            connection.fileState = .awaitingOffset
            let initial = PeerInitOut.peerInit(username: localUsername ?? "",
                                               type: ConnectionType.file) + fileInitPayload(token)
            connection.stream.start(host: address.host, port: address.port, initialBytes: initial)
            delegate?.peerManager(self, didOpenUploadConnection: connection.id,
                                  username: username, token: token)
            return connection.id
        }

        // We are unreachable directly (or address unknown): ask the
        // downloader to pierce through to our listener. The binding is
        // reported when the pierce frame arrives.
        inviteIndirectConnection(username: username, type: ConnectionType.file, token: token)
        return nil
    }

    /// Called when the server relays a ConnectToPeer('F') from the uploader.
    public func openDownloadConnection(username: String, host: String, port: UInt16, token: UInt32) {
        let connection = makeFileConnection(username: username)
        connection.fileState = .awaitingToken
        connection.stream.start(host: host, port: port,
                                initialBytes: PeerInitOut.pierceFirewall(token: token))
    }

    private func makeFileConnection(username: String) -> PeerConnection {
        let connection = PeerConnection(id: nextID(), stream: factory.makePeerStream(), kind: ConnectionType.file)
        connection.username = username
        connections[connection.id] = connection
        connection.stream.delegate = self
        return connection
    }

    private func fileInitPayload(_ token: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(token)
        return b.data
    }

    public func sendFileData(_ connectionID: UInt64, _ data: Data) {
        connections[connectionID]?.stream.send(data)
    }

    public func sendFileOffset(_ connectionID: UInt64, _ offset: UInt64) {
        var b = MessageBuffer()
        b.writeUInt64(offset)
        connections[connectionID]?.stream.send(b.data)
    }

    public func closeFileConnection(_ connectionID: UInt64) {
        if let connection = connections[connectionID] {
            connections[connectionID] = nil
            connection.stream.close()
        }
    }

    // MARK: - Distributed

    /// Send data on one specific connection (used to answer distributed
    /// searches on the 'D' connection they arrived on).
    public func sendDirect(_ connectionID: UInt64, _ data: Data) {
        connections[connectionID]?.stream.send(data)
    }

    public func sendToDistributedChildren(_ data: Data) {
        for connection in connections.values
        where connection.kind == ConnectionType.distributed && connection.isOpen {
            connection.stream.send(data)
        }
    }

    public func connectToParentCandidate(username: String, host: String, port: UInt16) {
        guard localUsername != nil else { return }
        let connection = PeerConnection(id: nextID(), stream: factory.makePeerStream(),
                                        kind: ConnectionType.distributed)
        connection.username = username
        connections[connection.id] = connection
        connection.stream.delegate = self
        connection.stream.start(host: host, port: port,
                                initialBytes: PeerInitOut.peerInit(username: localUsername ?? "",
                                                                   type: ConnectionType.distributed))
    }

    public func rejectParentCandidates() {
        for connection in connections.values where connection.kind == ConnectionType.distributed {
            connections[connection.id] = nil
            connection.stream.close()
        }
    }

    public func closeAll() {
        for connection in connections.values {
            connection.stream.close()
        }
        connections.removeAll()
        sessions.removeAll()
        pierceTokens.removeAll()
        for timer in indirectTimers.values {
            timer.invalidate()
        }
        indirectTimers.removeAll()
        listener.stop()
    }

    // MARK: - Indirect invitations

    /// Ask the server to relay a ConnectToPeer so `username` connects to our
    /// listener; `token` identifies the pierce frame.
    public func inviteIndirectConnection(username: String, type: String, token: UInt32) {
        pierceTokens[token] = (username, type)
        indirectRequestHandler?(username, type, token)

        let timer = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, self.pierceTokens[token] != nil else { return }
            self.pierceTokens[token] = nil
            self.indirectTimers[token] = nil
            self.cantConnectHandler?(token, username)
        }
        RunLoop.main.add(timer, forMode: .default)
        indirectTimers[token] = timer
    }

    /// A ConnectToPeer invitation from the server: connect out and pierce.
    public func handleIncomingIndirectInvitation(username: String, type: String, host: String,
                                                 port: UInt16, token: UInt32) {
        guard localUsername != nil else { return }
        switch type {
        case ConnectionType.file:
            openDownloadConnection(username: username, host: host, port: port, token: token)
        case ConnectionType.peer, ConnectionType.distributed:
            let connection = PeerConnection(id: nextID(), stream: factory.makePeerStream(), kind: type)
            connection.username = username
            connections[connection.id] = connection
            connection.stream.delegate = self
            connection.stream.start(host: host, port: port,
                                    initialBytes: PeerInitOut.pierceFirewall(token: token))
        default:
            break
        }
    }

    public func handleCantConnect(token: UInt32) {
        pierceTokens[token] = nil
        indirectTimers[token]?.invalidate()
        indirectTimers[token] = nil
    }

    // MARK: - Session plumbing

    private func session(for username: String) -> PeerSession {
        if let session = sessions[username] {
            return session
        }
        let session = PeerSession(username: username)
        sessions[username] = session
        return session
    }

    private func nextID() -> UInt64 {
        nextStreamID += 1
        return nextStreamID
    }

    private func attemptDirectConnection(_ session: PeerSession) {
        guard let address = session.address, !session.isConnecting, session.connection == nil else { return }
        session.isConnecting = true
        let connection = PeerConnection(id: nextID(), stream: factory.makePeerStream(), kind: ConnectionType.peer)
        connection.username = session.username
        session.connection = connection
        connections[connection.id] = connection
        connection.stream.delegate = self
        connection.stream.start(host: address.host, port: address.port,
                                initialBytes: PeerInitOut.peerInit(username: localUsername ?? "",
                                                                   type: ConnectionType.peer))

        let username = session.username
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard let session = self.sessions[username], let connection = session.connection,
                  !connection.isOpen else { return }
            self.abandon(connection: connection, session: session)

            if !session.usedIndirect {
                let token = self.tokens.next()
                session.usedIndirect = true
                self.pierceTokens[token] = (username, ConnectionType.peer)
                self.indirectRequestHandler?(username, ConnectionType.peer, token)

                let indirectTimer = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
                    guard let self, self.pierceTokens[token] != nil else { return }
                    self.pierceTokens[token] = nil
                    self.indirectTimers[token] = nil
                    if let session = self.sessions[username] {
                        session.isConnecting = false
                        session.connection = nil
                        session.pendingMessages.removeAll()
                        self.delegate?.peerManager(self, didFailPeerConnection: username)
                    }
                }
                RunLoop.main.add(indirectTimer, forMode: .default)
                self.indirectTimers[token] = indirectTimer
            } else {
                session.isConnecting = false
                session.connection = nil
                session.pendingMessages.removeAll()
                self.delegate?.peerManager(self, didFailPeerConnection: username)
            }
        }
        RunLoop.main.add(timer, forMode: .default)
    }

    private func abandon(connection: PeerConnection, session: PeerSession) {
        connections[connection.id] = nil
        connection.stream.close()
        if session.connection === connection {
            session.connection = nil
        }
    }

    // MARK: - Incoming stream routing (listener-accepted connections)

    private func handleAccepted(stream: any ByteStream) {
        let connection = PeerConnection(id: nextID(), stream: stream, kind: "?")
        connection.isOpen = true
        connections[connection.id] = connection
        stream.delegate = self
    }

    private func processFrame(_ connection: PeerConnection, body: Data) {
        var buffer = MessageBuffer(body)

        if connection.kind == "?" {
            parseAcceptedInit(connection, buffer: &buffer)
            return
        }

        switch connection.kind {
        case ConnectionType.peer:
            guard let code = try? buffer.readUInt32() else { return }
            if let username = connection.username {
                delegate?.peerManager(self, didReceivePeerMessageCode: code, body: buffer, from: username)
            }

        case ConnectionType.distributed:
            guard let code = try? buffer.readByte() else { return }
            if let username = connection.username {
                delegate?.peerManager(self, didReceiveDistribCode: code, body: buffer,
                                      from: username, connectionID: connection.id)
            }

        default:
            break
        }
    }

    /// First frame of a listener-accepted connection is always a 1-byte-code
    /// init message that determines the connection kind.
    private func parseAcceptedInit(_ connection: PeerConnection, buffer: inout MessageBuffer) {
        guard let codeByte = try? buffer.readByte() else {
            connection.stream.close()
            connections[connection.id] = nil
            return
        }

        switch codeByte {
        case PeerInitCode.pierceFirewall.rawValue:
            let token = (try? buffer.readUInt32()) ?? 0
            guard let entry = pierceTokens[token] else {
                // Unknown/stale pierce token: refuse the connection.
                connections[connection.id] = nil
                connection.stream.close()
                return
            }
            pierceTokens[token] = nil
            indirectTimers[token]?.invalidate()
            indirectTimers[token] = nil
            connection.kind = entry.kind
            connection.username = entry.username

            switch entry.kind {
            case ConnectionType.peer:
                let session = session(for: entry.username)
                session.isConnecting = false
                if session.connection == nil {
                    session.connection = connection
                }
                sendPendingMessages(connection, session: session)
            case ConnectionType.file:
                // The downloader pierced through to us: we are the uploader.
                connection.fileState = .awaitingOffset
                connection.stream.send(fileInitPayload(token))
                delegate?.peerManager(self, didOpenUploadConnection: connection.id,
                                      username: entry.username, token: token)
            default:
                break
            }

        case PeerInitCode.peerInit.rawValue:
            let username = (try? buffer.readString()) ?? ""
            let type = (try? buffer.readString()) ?? ConnectionType.peer
            connection.kind = type
            connection.username = username

            switch type {
            case ConnectionType.peer:
                // Bind the accepted connection to the session so replies
                // reuse it instead of dialing out again.
                let session = session(for: username)
                if session.connection == nil {
                    session.connection = connection
                }
                sendPendingMessages(connection, session: session)
            case ConnectionType.file:
                // An uploader connected to us directly: they will send the
                // raw token next; we are the downloader.
                connection.fileState = .awaitingToken
            case ConnectionType.distributed:
                // A child connected to us in the distributed tree.
                if let username = connection.username {
                    delegate?.peerManager(self, didAcceptChildConnection: connection.id, username: username)
                }
            default:
                break
            }

        default:
            connections[connection.id] = nil
            connection.stream.close()
        }
    }

    private func sendPendingMessages(_ connection: PeerConnection, session: PeerSession) {
        guard connection.isOpen else { return }
        let pending = session.pendingMessages
        session.pendingMessages.removeAll()
        for message in pending {
            connection.stream.send(message)
        }
    }

    // MARK: - File connection byte handling

    private func handleFileBytes(_ connection: PeerConnection, data: Data) {
        guard var state = connection.fileState else { return }
        connection.rawBuffer.append(data)

        func takeBytes(_ count: Int) -> Data? {
            guard connection.rawBuffer.count >= count else { return nil }
            let taken = connection.rawBuffer.prefix(count)
            connection.rawBuffer.removeFirst(count)
            return Data(taken)
        }

        switch state {
        case .awaitingInitFrame:
            // This path is handled by the frame assembler (parseAcceptedInit);
            // any stray bytes are unexpected.
            return

        case .awaitingToken:
            guard let tokenData = takeBytes(4) else { return }
            var b = MessageBuffer(tokenData)
            let token = (try? b.readUInt32()) ?? 0
            state = .receivingData
            connection.fileState = state
            if let username = connection.username {
                delegate?.peerManager(self, didOpenDownloadConnection: connection.id,
                                      username: username, token: token)
            }
            if !connection.rawBuffer.isEmpty {
                let chunk = connection.rawBuffer
                connection.rawBuffer.removeAll()
                delegate?.peerManager(self, didReceiveFileData: connection.id, data: chunk)
            }

        case .receivingData:
            let chunk = connection.rawBuffer
            connection.rawBuffer.removeAll()
            if !chunk.isEmpty {
                delegate?.peerManager(self, didReceiveFileData: connection.id, data: chunk)
            }

        case .awaitingOffset:
            guard let offsetData = takeBytes(8) else { return }
            var b = MessageBuffer(offsetData)
            let offset = (try? b.readUInt64()) ?? 0
            state = .uploading
            connection.fileState = state
            delegate?.peerManager(self, didReceiveUploadOffset: connection.id, offset: offset)

        case .uploading:
            connection.rawBuffer.removeAll()
        }
    }
}

extension PeerConnectionManager: ByteStreamDelegate {
    public func byteStreamDidOpen(_ stream: any ByteStream) {
        guard let connection = connections.values.first(where: { $0.stream === stream }) else { return }
        connection.isOpen = true

        if connection.kind == ConnectionType.peer, let username = connection.username,
           let session = sessions[username] {
            session.isConnecting = false
            sendPendingMessages(connection, session: session)
        }
    }

    public func byteStream(_ stream: any ByteStream, didReceive data: Data) {
        guard let connection = connections.values.first(where: { $0.stream === stream }) else { return }

        if connection.kind == ConnectionType.file {
            handleFileBytes(connection, data: data)
            return
        }

        do {
            try connection.assembler.feed(data) { [weak self] body in
                self?.processFrame(connection, body: body)
            }
        } catch {
            connections[connection.id] = nil
            stream.close()
        }
    }

    public func byteStream(_ stream: any ByteStream, didCloseWith error: (any Error)?) {
        guard let connection = connections.values.first(where: { $0.stream === stream }) else { return }
        connections[connection.id] = nil

        if connection.kind == ConnectionType.file {
            delegate?.peerManager(self, didCloseFileConnection: connection.id, error: error)
            return
        }
        if connection.kind == ConnectionType.peer, let username = connection.username {
            sessions[username]?.connection = nil
        }
        if connection.kind == ConnectionType.distributed, let username = connection.username {
            delegate?.peerManager(self, distributedConnectionClosed: username)
        }
    }
}

extension PeerConnectionManager: ListenerServiceDelegate {
    public func listener(_ listener: any ListenerService, didAccept stream: any ByteStream) {
        handleAccepted(stream: stream)
    }

    public func listener(_ listener: any ListenerService, didFailWith error: any Error) {
        listenErrorHandler?(error)
    }
}


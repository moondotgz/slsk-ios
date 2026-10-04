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
    func sendFileData(_ connectionID: UInt64, _ data: Data, completion: @escaping ((any Error)?) -> Void)
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
    public var onDiagnostic: ((String) -> Void)?

    public let factory: any TransportFactory
    public let listener: any ListenerService

    private let tokens = TokenGenerator()
    private var nextStreamID: UInt64 = 0
    private var maintenanceTimer: Timer?
    private let maximumConnections = 64
    private let maximumSearchSessions = 16
    public var activeConnectionCount: Int { connections.count }

    private final class PeerSession {
        var username: String
        var address: (host: String, port: UInt16)?
        var addressRequested = false
        var addressTimer: Timer?
        var connection: PeerConnection?
        var pendingMessages: [Data] = []
        var isConnecting = false
        var usedIndirect = false
        var searchOnly = false
        var lastActivity = Date()

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
        var uploadToken: UInt32?
        var connectTimer: Timer?
        var isDistributedChild = false
        var lastActivity = Date()

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

    deinit { maintenanceTimer?.invalidate() }

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
        session.addressTimer?.invalidate()
        session.addressTimer = nil

        if session.address != nil && !session.pendingMessages.isEmpty {
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
        sendToPeer(username, data, searchOnly: false)
    }

    public func sendSearchResponse(_ username: String, _ data: Data) {
        let existing = sessions[username]
        let alreadyActive = existing.map { $0.connection != nil || $0.addressRequested || $0.isConnecting } ?? false
        guard alreadyActive || sessions.values.filter({
            $0.searchOnly && ($0.connection != nil || $0.addressRequested || $0.isConnecting)
        }).count < maximumSearchSessions else { return }
        sendToPeer(username, data, searchOnly: true)
    }

    private func sendToPeer(_ username: String, _ data: Data, searchOnly: Bool) {
        guard localUsername != nil else { return }
        let existed = sessions[username] != nil
        let session = session(for: username)
        if !existed || (session.connection == nil && !session.isConnecting && !session.addressRequested && session.pendingMessages.isEmpty) {
            session.searchOnly = searchOnly
        }
        if !searchOnly { session.searchOnly = false }
        session.lastActivity = Date()

        if let connection = session.connection, connection.isOpen, connection.kind == ConnectionType.peer {
            connection.lastActivity = Date()
            connection.stream.send(data)
            return
        }

        if searchOnly && !session.pendingMessages.isEmpty { return }
        session.pendingMessages.append(data)
        guard !session.isConnecting else { return }
        session.usedIndirect = false

        if session.address != nil {
            attemptDirectConnection(session)
        } else if !session.addressRequested {
            session.addressRequested = true
            let timer = Timer(fire: Date().addingTimeInterval(10), interval: 10, repeats: false) { [weak self, weak session] _ in
                guard let self, let session, session.addressRequested else { return }
                session.addressRequested = false
                session.addressTimer = nil
                session.pendingMessages.removeAll()
                self.delegate?.peerManager(self, didFailPeerConnection: username)
            }
            session.addressTimer = timer
            RunLoop.main.add(timer, forMode: .common)
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
        guard admitConnection(file: true) else { return nil }
        let session = session(for: username)

        if let address = session.address {
            let connection = makeFileConnection(username: username)
            connection.fileState = .awaitingOffset
            connection.uploadToken = token
            let timer = Timer(fire: Date().addingTimeInterval(10), interval: 10, repeats: false) { [weak self, weak connection] _ in
                guard let self, let connection, !connection.isOpen,
                      self.connections[connection.id] != nil else { return }
                self.fallbackUploadConnection(connection)
            }
            connection.connectTimer = timer
            RunLoop.main.add(timer, forMode: .default)
            let initial = PeerInitOut.peerInit(username: localUsername ?? "",
                                               type: ConnectionType.file) + fileInitPayload(token)
            connection.stream.start(host: address.host, port: address.port, initialBytes: initial)
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
        guard admitConnection(file: true) else { return }
        let connection = makeFileConnection(username: username)
        onDiagnostic?("Reverse file invitation: socket=\(connection.id), peer=\(username), endpoint=\(host):\(port), pierceToken=\(token)")
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

    public func sendFileData(_ connectionID: UInt64, _ data: Data, completion: @escaping ((any Error)?) -> Void) {
        guard let connection = connections[connectionID] else {
            completion(SlskError.notConnected)
            return
        }
        connection.lastActivity = Date()
        connection.stream.send(data, completion: completion)
    }

    public func sendFileOffset(_ connectionID: UInt64, _ offset: UInt64) {
        var b = MessageBuffer()
        b.writeUInt64(offset)
        connections[connectionID]?.stream.send(b.data)
    }

    public func closeFileConnection(_ connectionID: UInt64) {
        if let connection = connections[connectionID] {
            onDiagnostic?("Closing file socket \(connectionID): peer=\(connection.username ?? "unknown"), state=\(String(describing: connection.fileState))")
            connections[connectionID] = nil
            connection.connectTimer?.invalidate()
            connection.stream.close()
        }
    }

    // MARK: - Distributed

    /// Send distributed branch metadata on one specific connection.
    public func sendDirect(_ connectionID: UInt64, _ data: Data) {
        connections[connectionID]?.stream.send(data)
    }

    public func sendToDistributedChildren(_ data: Data) {
        for connection in connections.values
        where connection.kind == ConnectionType.distributed && connection.isDistributedChild && connection.isOpen {
            connection.stream.send(data)
        }
    }

    public func connectToParentCandidate(username: String, host: String, port: UInt16) {
        guard localUsername != nil else { return }
        guard !connections.values.contains(where: { $0.kind == ConnectionType.distributed && $0.username == username }),
              admitConnection() else { return }
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

    public func selectDistributedParent(_ username: String) {
        for connection in connections.values where connection.kind == ConnectionType.distributed
            && !connection.isDistributedChild && connection.username != username {
            connections[connection.id] = nil
            connection.stream.close()
        }
    }

    public func closeAll() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        for session in sessions.values { session.addressTimer?.invalidate() }
        for connection in connections.values {
            connection.connectTimer?.invalidate()
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

        let timer = Timer(fire: Date().addingTimeInterval(20), interval: 20, repeats: false) { [weak self] _ in
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
            guard admitConnection() else {
                sendCantConnectToPeer(token: token, username: username)
                return
            }
            let connection = PeerConnection(id: nextID(), stream: factory.makePeerStream(), kind: type)
            connection.username = username
            connections[connection.id] = connection
            connection.stream.delegate = self
            if type == ConnectionType.peer {
                let session = session(for: username)
                if let previous = session.connection { abandon(connection: previous, session: session) }
                session.connection = connection
                session.isConnecting = true
            }
            connection.stream.start(host: host, port: port,
                                    initialBytes: PeerInitOut.pierceFirewall(token: token))
        default:
            break
        }
    }

    public func handleCantConnect(token: UInt32) {
        let invitation = pierceTokens.removeValue(forKey: token)
        indirectTimers[token]?.invalidate()
        indirectTimers[token] = nil
        if let invitation, invitation.kind == ConnectionType.peer,
           let session = sessions[invitation.username] {
            session.isConnecting = false
            session.pendingMessages.removeAll()
            delegate?.peerManager(self, didFailPeerConnection: invitation.username)
        }
    }

    // MARK: - Session plumbing

    private func session(for username: String) -> PeerSession {
        startMaintenance()
        if let session = sessions[username] {
            return session
        }
        let session = PeerSession(username: username)
        sessions[username] = session
        return session
    }

    private func nextID() -> UInt64 {
        startMaintenance()
        nextStreamID += 1
        return nextStreamID
    }

    private func attemptDirectConnection(_ session: PeerSession) {
        guard let address = session.address, !session.isConnecting, session.connection == nil else { return }
        guard admitConnection() else {
            session.pendingMessages.removeAll()
            if !session.searchOnly { delegate?.peerManager(self, didFailPeerConnection: session.username) }
            return
        }
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
        let timer = Timer(fire: Date().addingTimeInterval(10), interval: 10, repeats: false) { [weak self, weak connection] _ in
            guard let self, let connection else { return }
            guard let session = self.sessions[username], session.connection === connection,
                  !connection.isOpen else { return }
            self.abandon(connection: connection, session: session)
            self.attemptIndirectConnection(session)
        }
        connection.connectTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    private func attemptIndirectConnection(_ session: PeerSession) {
        guard !session.usedIndirect else {
            session.isConnecting = false
            session.pendingMessages.removeAll()
            delegate?.peerManager(self, didFailPeerConnection: session.username)
            return
        }
        let token = tokens.next()
        let username = session.username
        session.usedIndirect = true
        session.isConnecting = true
        pierceTokens[token] = (username, ConnectionType.peer)
        indirectRequestHandler?(username, ConnectionType.peer, token)
        let timer = Timer(fire: Date().addingTimeInterval(20), interval: 20, repeats: false) { [weak self] _ in
            guard let self, self.pierceTokens.removeValue(forKey: token) != nil else { return }
            self.indirectTimers[token] = nil
            session.isConnecting = false
            session.pendingMessages.removeAll()
            self.delegate?.peerManager(self, didFailPeerConnection: username)
        }
        indirectTimers[token] = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    private func fallbackUploadConnection(_ connection: PeerConnection) {
        guard let username = connection.username, let token = connection.uploadToken else { return }
        connections[connection.id] = nil
        connection.connectTimer?.invalidate()
        connection.stream.close()
        inviteIndirectConnection(username: username, type: ConnectionType.file, token: token)
    }

    private func abandon(connection: PeerConnection, session: PeerSession) {
        connections[connection.id] = nil
        connection.connectTimer?.invalidate()
        connection.stream.close()
        if session.connection === connection {
            session.connection = nil
        }
    }

    // MARK: - Incoming stream routing (listener-accepted connections)

    private func handleAccepted(stream: any ByteStream) {
        guard admitConnection() else { stream.close(); return }
        let connection = PeerConnection(id: nextID(), stream: stream, kind: "?")
        connection.isOpen = true
        connections[connection.id] = connection
        stream.delegate = self
        stream.start(host: nil, port: 0, initialBytes: nil)
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
                onDiagnostic?("Rejected PierceFirewall: socket=\(connection.id), unknown or expired pierceToken=\(token)")
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
            onDiagnostic?("Accepted PierceFirewall: socket=\(connection.id), peer=\(entry.username), type=\(entry.kind), pierceToken=\(token)")

            switch entry.kind {
            case ConnectionType.peer:
                let session = session(for: entry.username)
                bindPeerConnection(connection, session: session)
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
            onDiagnostic?("Incoming PeerInit: socket=\(connection.id), peer=\(username), type=\(type)")

            switch type {
            case ConnectionType.peer:
                // Bind the accepted connection to the session so replies
                // reuse it instead of dialing out again.
                let session = session(for: username)
                bindPeerConnection(connection, session: session)
            case ConnectionType.file:
                // An uploader connected to us directly: they will send the
                // raw token next; we are the downloader.
                connection.fileState = .awaitingToken
            case ConnectionType.distributed:
                // A child connected to us in the distributed tree.
                connection.isDistributedChild = true
                if let username = connection.username {
                    delegate?.peerManager(self, didAcceptChildConnection: connection.id, username: username)
                }
            default:
                connections[connection.id] = nil
                connection.stream.close()
            }

        default:
            connections[connection.id] = nil
            connection.stream.close()
        }
    }

    private func bindPeerConnection(_ connection: PeerConnection, session: PeerSession) {
        if let previous = session.connection, previous !== connection {
            abandon(connection: previous, session: session)
        }
        session.connection = connection
        session.isConnecting = false
        session.usedIndirect = false
        session.addressRequested = false
        session.addressTimer?.invalidate()
        session.addressTimer = nil
        for (token, invitation) in pierceTokens where invitation.username == session.username
            && invitation.kind == ConnectionType.peer {
            pierceTokens[token] = nil
            indirectTimers.removeValue(forKey: token)?.invalidate()
        }
        sendPendingMessages(connection, session: session)
    }

    private func sendPendingMessages(_ connection: PeerConnection, session: PeerSession) {
        guard connection.isOpen else { return }
        let pending = session.pendingMessages
        session.pendingMessages.removeAll()
        for message in pending {
            connection.lastActivity = Date()
            connection.stream.send(message)
        }
    }

    private func startMaintenance() {
        guard maintenanceTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.maintainConnections()
        }
        maintenanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func admitConnection(file: Bool = false) -> Bool {
        maintainConnections()
        return connections.count < (file ? maximumConnections : maximumConnections - 16)
    }

    // Nicotine+ slskproto.py expires idle peer sockets rather than retaining every search peer.
    func maintainConnections(now: Date = Date()) {
        for connection in Array(connections.values) {
            let age = now.timeIntervalSince(connection.lastActivity)
            let awaitingFileHandshake: Bool
            switch connection.fileState {
            case .awaitingInitFrame?, .awaitingToken?, .awaitingOffset?: awaitingFileHandshake = true
            default: awaitingFileHandshake = false
            }
            let expired = (!connection.isOpen || connection.kind == "?" || awaitingFileHandshake) ? age > 30
                : connection.kind == ConnectionType.peer && age > 60
            guard expired else { continue }
            onDiagnostic?("Socket \(connection.id) expired: peer=\(connection.username ?? "unknown"), type=\(connection.kind), activeSockets=\(connections.count)")
            byteStream(connection.stream, didCloseWith: connection.isOpen ? nil : SlskError.notConnected)
            connection.stream.close()
        }
        for (username, session) in sessions where session.connection == nil && !session.isConnecting
            && !session.addressRequested && session.pendingMessages.isEmpty
            && now.timeIntervalSince(session.lastActivity) > 300 {
            sessions[username] = nil
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
            onDiagnostic?("FileTransferInit: socket=\(connection.id), peer=\(connection.username ?? "unknown"), token=\(token)")
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
    public func byteStream(_ stream: any ByteStream, isWaitingWith error: any Error) {
        guard let connection = connections.values.first(where: { $0.stream === stream }) else { return }
        onDiagnostic?("Socket \(connection.id) waiting: peer=\(connection.username ?? "unknown"), type=\(connection.kind), activeSockets=\(connections.count), error=\(error.localizedDescription)")
    }

    public func byteStreamDidOpen(_ stream: any ByteStream) {
        guard let connection = connections.values.first(where: { $0.stream === stream }) else { return }
        connection.isOpen = true
        connection.lastActivity = Date()
        onDiagnostic?("Socket \(connection.id) ready: peer=\(connection.username ?? "unknown"), type=\(connection.kind)")
        connection.connectTimer?.invalidate()
        if connection.kind == ConnectionType.file, let token = connection.uploadToken,
           let username = connection.username {
            delegate?.peerManager(self, didOpenUploadConnection: connection.id, username: username, token: token)
        }

        if connection.kind == ConnectionType.peer, let username = connection.username,
           let session = sessions[username] {
            bindPeerConnection(connection, session: session)
        }
    }

    public func byteStream(_ stream: any ByteStream, didReceive data: Data) {
        guard let connection = connections.values.first(where: { $0.stream === stream }) else { return }
        connection.lastActivity = Date()

        if connection.kind == ConnectionType.file {
            handleFileBytes(connection, data: data)
            return
        }

        do {
            connection.assembler.append(data)
            while let body = try connection.assembler.nextFrame() {
                processFrame(connection, body: body)
                guard connections[connection.id] != nil else { return }
                if connection.kind == ConnectionType.file {
                    let raw = connection.assembler.takePendingBytes()
                    handleFileBytes(connection, data: raw)
                    return
                }
            }
        } catch {
            onDiagnostic?("Socket \(connection.id) framing error: \(error.localizedDescription)")
            byteStream(stream, didCloseWith: error)
            stream.close()
        }
    }

    public func byteStream(_ stream: any ByteStream, didCloseWith error: (any Error)?) {
        guard let connection = connections.values.first(where: { $0.stream === stream }) else { return }
        onDiagnostic?("Socket \(connection.id) closed: peer=\(connection.username ?? "unknown"), type=\(connection.kind), state=\(String(describing: connection.fileState)), error=\(error?.localizedDescription ?? "EOF")")
        connection.connectTimer?.invalidate()
        if !connection.isOpen, connection.kind == ConnectionType.file, connection.uploadToken != nil {
            fallbackUploadConnection(connection)
            return
        }
        connections[connection.id] = nil
        stream.close()

        if connection.kind == ConnectionType.file {
            delegate?.peerManager(self, didCloseFileConnection: connection.id, error: error)
            return
        }
        if connection.kind == ConnectionType.peer, let username = connection.username {
            if let session = sessions[username], session.connection === connection {
                session.connection = nil
                if !connection.isOpen { attemptIndirectConnection(session) }
                else { session.isConnecting = false }
            }
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

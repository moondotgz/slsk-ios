import Foundation
#if canImport(Combine)
import Combine
#endif

public enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case loggingIn
    case loggedIn
    case failed(String)
}

/// The complete Soulseek client: server session, peer network, transfers,
/// search, shares, chat and the distributed network. All callbacks arrive on
/// the main queue (transports guarantee this).
public final class SoulseekClient: ObservableObject {
    // MARK: Published UI state

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var loggedInUsername: String?
    @Published public private(set) var serverBanner: String = ""
    @Published public private(set) var privilegesSeconds: UInt32 = 0
    @Published public private(set) var isAway: Bool = false
    @Published public private(set) var isGlobalRoomFeedEnabled = false
    @Published public private(set) var users: [String: UserInfo] = [:]
    @Published public private(set) var userInterests: [String: UserInterestsInfo] = [:]
    @Published public private(set) var privilegedUsers: Set<String> = []
    @Published public private(set) var roomCounts: [String: UInt32] = [:]
    @Published public private(set) var sharesRevision: Int = 0
    @Published public private(set) var chatRevision: Int = 0
    @Published public private(set) var transferRevision: Int = 0
    @Published public private(set) var searchRevision: Int = 0
    @Published public private(set) var browseRevision: Int = 0
    @Published public private(set) var similarUsers: [(String, UInt32)] = []
    @Published public private(set) var recommendations: [Recommendation] = []
    @Published public private(set) var unrecommendations: [Recommendation] = []
    @Published public private(set) var itemRecommendations: [Recommendation] = []
    @Published public private(set) var itemSimilarUsers: [String] = []
    @Published public private(set) var listenPort: UInt16 = 0

    // MARK: Services

    public let chat = ChatManager()
    public let search = SearchEngine()
    public let shares = SharesManager()
    public let distributed = DistributedManager()
    public let peerManager: PeerConnectionManager
    public let transfers: TransferManager
    /// Active configuration. Mutable so the UI can edit it; persist with
    /// `saveConfig()`.
    public var config: ClientConfiguration
    public let storage: Storage

    // MARK: Internals

    private let factory: any TransportFactory
    private var serverStream: (any ByteStream)?
    private var serverAssembler = FrameAssembler()
    private var reconnectAttempts = 0
    private var reconnectTimer: Timer?
    private var pingTimer: Timer?
    private var pendingIndirectTokens: [UInt32: String] = [:] // token → username
    private var browseSessions: [String: BrowseSession] = [:]
    private var folderContentsHandlers: [UInt32: ([String: [RemoteFileInfo]]) -> Void] = [:]
    private var userInfoHandlers: [String: (String, PeerUserInfo) -> Void] = [:]
    private let folderTokens = TokenGenerator()
    private var watchedForTransfers = Set<String>()

    public init(factory: any TransportFactory, storage: Storage, config: ClientConfiguration) {
        self.factory = factory
        self.storage = storage
        self.config = config
        peerManager = PeerConnectionManager(factory: factory)
        transfers = TransferManager()
        wireServices()
    }

    // MARK: - Lifecycle

    public func start() {
        loadPersistedState()
        sharesRevision += 1
    }

    public var isLoggedIn: Bool { connectionState == .loggedIn }

    public func connect() {
        guard serverStream == nil else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connectionState = .connecting
        let stream = factory.makeServerStream()
        serverStream = stream
        stream.delegate = self
        stream.start(host: config.serverHost, port: config.serverPort, initialBytes: nil)
    }

    public func login(username: String, password: String) {
        config.username = username
        config.password = password
        saveConfig()
        connect()
    }

    public func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        serverStream?.close()
        serverStream = nil
        peerManager.localUsername = nil
        peerManager.closeAll()
        connectionState = .disconnected
        loggedInUsername = nil
        isGlobalRoomFeedEnabled = false
        search.setWishlistInterval(0)
        transfers.serverWentOffline()
    }

    public func saveConfig() {
        storage.save(config, as: "config")
    }

    public func removeSearchSession(token: UInt32) {
        search.removeSession(token: token)
        searchRevision += 1
    }

    public func clearPrivateThread(username: String) {
        chat.clearPrivateThread(username: username)
        chatRevision += 1
    }

    private func loadPersistedState() {
        if let saved: ClientConfiguration = storage.load(ClientConfiguration.self, as: "config") {
            config = saved
        }
        chat.loadHistory(storage: storage)
        transfers.configure(storage: storage, gateway: peerManager, shares: shares)
        transfers.uploadSlots = config.uploadSlots
        transfers.maxDownloadConnections = config.maxDownloadConnections
        search.setWishlist(config.wishlist)
    }

    // MARK: - Service wiring

    private func wireServices() {
        // Peer manager
        peerManager.delegate = self
        peerManager.addressRequestHandler = { [weak self] username in
            self?.send(ServerOut.getPeerAddress(username))
        }
        peerManager.indirectRequestHandler = { [weak self] username, type, token in
            self?.pendingIndirectTokens[token] = username
            self?.send(ServerOut.connectToPeer(token: token, username: username, type: type))
        }
        peerManager.cantConnectHandler = { [weak self] token, username in
            self?.send(ServerOut.cantConnectToPeer(token: token, username: username))
        }
        peerManager.portChangedHandler = { [weak self] port in
            guard let self, self.isLoggedIn else { return }
            self.listenPort = port
            self.send(ServerOut.setWaitPort(UInt32(port)))
        }
        peerManager.listenErrorHandler = { [weak self] _ in
            self?.listenPort = 0
        }

        // Transfers
        transfers.onChanged = { [weak self] in self?.transferRevision += 1 }
        transfers.onUploadFinishedSpeed = { [weak self] speed in
            self?.send(ServerOut.sendUploadSpeed(speed))
        }
        transfers.onUserWatchRequested = { [weak self] username in
            self?.watchUser(username)
        }
        transfers.isBanned = { [weak self] username in
            self?.config.bannedUsers.contains(username) ?? false
        }
        transfers.isIgnored = { [weak self] username in
            self?.config.ignoredUsers.contains(username) ?? false
        }

        // Search
        search.onResultsChanged = { [weak self] _ in self?.searchRevision += 1 }
        search.onWishlistSearch { [weak self] token, item in
            guard let self, self.isLoggedIn else { return }
            self.send(ServerOut.wishlistSearch(token: token, query: item))
        }

        // Distributed
        distributed.onSendToServer = { [weak self] data in self?.send(data) }
        distributed.onSendToChildren = { [weak self] data in self?.peerManager.sendToDistributedChildren(data) }
        distributed.onSendToConnection = { [weak self] id, data in self?.peerManager.sendDirect(id, data) }
        distributed.onBranchChanged = { [weak self] in
            guard let self else { return }
            if let parent = self.distributed.parentUsername {
                self.peerManager.selectDistributedParent(parent)
            }
            self.updateAcceptChildren()
            self.chatRevision += 1
        }
        distributed.onDistributedSearch = { [weak self] username, token, query, connectionID in
            self?.handleIncomingSearch(username: username, token: token, query: query,
                                       connectionID: connectionID)
        }
    }

    // MARK: - Sending

    private func send(_ data: Data) {
        guard isLoggedIn || connectionState == .loggingIn || connectionState == .connecting,
              let serverStream else { return }
        serverStream.send(data)
    }

    // MARK: - Server stream events

    private func handleServerOpen() {
        connectionState = .loggingIn
        send(ServerOut.login(username: config.username, password: config.password))
    }

    private func handleServerClosed(_ error: (any Error)?) {
        serverStream = nil
        pingTimer?.invalidate()
        pingTimer = nil
        serverAssembler.reset()
        peerManager.localUsername = nil
        peerManager.closeAll()
        loggedInUsername = nil
        isGlobalRoomFeedEnabled = false
        search.setWishlistInterval(0)

        if connectionState == .loggedIn {
            connectionState = .disconnected
            transfers.serverWentOffline()
            scheduleReconnect()
        } else if connectionState == .connecting || connectionState == .loggingIn {
            connectionState = .failed("Could not reach server")
        }
    }

    private func scheduleReconnect() {
        reconnectAttempts += 1
        let delay = min(300, TimeInterval(10 * reconnectAttempts))
        let timer = Timer(fire: Date().addingTimeInterval(delay), interval: delay, repeats: false) { [weak self] _ in
            guard let self, !self.isLoggedIn else { return }
            self.reconnectAttempts = 0
            self.connect()
        }
        RunLoop.main.add(timer, forMode: .default)
        reconnectTimer = timer
    }

    private func handleServerFrame(_ body: Data) {
        var buffer = MessageBuffer(body)
        guard let code = try? buffer.readUInt32() else { return }

        switch code {
        case ServerCode.login:
            handleLogin(&buffer)
        case ServerCode.getPeerAddress:
            if let user = try? buffer.readString(),
               let host = try? buffer.readIPAddress(),
               let port = try? buffer.readUInt32() {
                peerManager.setPeerAddress(user, host: host, port: UInt16(clamping: port))
            }
        case ServerCode.watchUser:
            handleWatchUser(&buffer)
        case ServerCode.getUserStatus:
            if let user = try? buffer.readString(),
               let status = try? buffer.readUInt32(),
               let privileged = try? buffer.readBool() {
                var info = users[user] ?? UserInfo()
                info.status = status
                info.privileged = privileged
                users[user] = info
                if status == UserStatusValue.offline {
                    transfers.handleUserWentOffline(user)
                } else {
                    transfers.handleUserOnline(user)
                }
            }
        case ServerCode.sayChatroom:
            if let room = try? buffer.readString(),
               let user = try? buffer.readString(),
               let message = try? buffer.readString() {
                chat.addRoomMessage(room: room, username: user, text: message, isSelf: user == loggedInUsername)
                chatRevision += 1
            }
        case ServerCode.joinRoom:
            handleJoinRoom(&buffer)
        case ServerCode.leaveRoom:
            if let room = try? buffer.readString() {
                chat.leaveRoom(named: room)
                chatRevision += 1
            }
        case ServerCode.userJoinedRoom:
            if let room = try? buffer.readString(),
               let user = try? buffer.readString(),
               let data = try? parseUserData(&buffer) {
                chat.userJoined(room: room, username: user)
                var info = users[user] ?? UserInfo()
                info.status = data.status
                info.stats = data.stats
                info.country = data.country
                users[user] = info
                chatRevision += 1
            }
        case ServerCode.userLeftRoom:
            if let room = try? buffer.readString(),
               let user = try? buffer.readString() {
                chat.userLeft(room: room, username: user)
                chatRevision += 1
            }
        case ServerCode.connectToPeer:
            if let user = try? buffer.readString(),
               let type = try? buffer.readString(),
               let host = try? buffer.readIPAddress(),
               let port = try? buffer.readUInt32(),
               let token = try? buffer.readUInt32() {
                if type == ConnectionType.peer || type == ConnectionType.file || type == ConnectionType.distributed {
                    peerManager.handleIncomingIndirectInvitation(username: user, type: type,
                                                                 host: host, port: UInt16(clamping: port),
                                                                 token: token)
                } else {
                    send(ServerOut.cantConnectToPeer(token: token, username: user))
                }
            }
        case ServerCode.messageUser:
            if let id = try? buffer.readUInt32(),
               let timestamp = try? buffer.readUInt32(),
               let user = try? buffer.readString(),
               let message = try? buffer.readString() {
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                chat.addPrivateMessage(username: user, text: message, isSelf: false, timestamp: date)
                send(ServerOut.messageAcked(id))
                chatRevision += 1
            }
        case ServerCode.fileSearch:
            if let user = try? buffer.readString(),
               let token = try? buffer.readUInt32(),
               let query = try? buffer.readString() {
                handleIncomingSearch(username: user, token: token, query: query, connectionID: nil)
            }
        case ServerCode.getUserStats:
            if let user = try? buffer.readString(),
               let avgSpeed = try? buffer.readUInt32(),
               let uploads = try? buffer.readUInt32(),
               let _ = try? buffer.readUInt32(),
               let files = try? buffer.readUInt32(),
               let dirs = try? buffer.readUInt32() {
                var info = users[user] ?? UserInfo()
                info.stats.avgSpeed = avgSpeed
                info.stats.uploads = uploads
                info.stats.sharedFiles = files
                info.stats.sharedFolders = dirs
                users[user] = info
                if user == loggedInUsername {
                    distributed.uploadSpeed = avgSpeed
                    updateAcceptChildren()
                }
                transferRevision += 1
            }
        case ServerCode.relogged:
            disconnect()
            connectionState = .failed("Logged in from another location")
        case ServerCode.roomList:
            handleRoomList(&buffer)
        case ServerCode.adminMessage:
            if let message = try? buffer.readString() {
                serverBanner = message
                chatRevision += 1
            }
        case ServerCode.privilegedUsers:
            if let count = try? buffer.readUInt32() {
                var set = Set<String>()
                for _ in 0 ..< count {
                    if let user = try? buffer.readString() {
                        set.insert(user)
                    }
                }
                privilegedUsers = set
            }
        case ServerCode.parentMinSpeed:
            distributed.parentMinSpeed = (try? buffer.readUInt32()) ?? 0
            updateAcceptChildren()
        case ServerCode.parentSpeedRatio:
            distributed.parentSpeedRatio = (try? buffer.readUInt32()) ?? 0
            updateAcceptChildren()
        case ServerCode.checkPrivileges:
            privilegesSeconds = (try? buffer.readUInt32()) ?? 0
        case ServerCode.embeddedMessage:
            handleEmbeddedMessage(&buffer)
        case ServerCode.acceptChildren:
            break // we send this
        case ServerCode.possibleParents:
            handlePossibleParents(&buffer)
        case ServerCode.wishlistInterval:
            search.setWishlistInterval((try? buffer.readUInt32()) ?? 600)
        case ServerCode.similarUsers:
            var list: [(String, UInt32)] = []
            if let count = try? buffer.readUInt32() {
                for _ in 0 ..< count {
                    if let user = try? buffer.readString(), let rating = try? buffer.readUInt32() {
                        list.append((user, rating))
                    }
                }
            }
            similarUsers = list
        case ServerCode.recommendations, ServerCode.globalRecommendations:
            parseRecommendations(&buffer)
        case ServerCode.userInterests:
            if let username = try? buffer.readString(),
               let likes = try? readStringList(&buffer), let hates = try? readStringList(&buffer) {
                userInterests[username] = UserInterestsInfo(likes: likes, hates: hates)
            }
        case ServerCode.itemRecommendations:
            if let item = try? buffer.readString() {
                parseRecommendations(&buffer, isItem: true)
                _ = item
            }
        case ServerCode.itemSimilarUsers:
            if let _ = try? buffer.readString(), let count = try? buffer.readUInt32() {
                var names: [String] = []
                for _ in 0 ..< count {
                    if let user = try? buffer.readString() {
                        names.append(user)
                    }
                }
                itemSimilarUsers = names
            }
        case ServerCode.roomTickers:
            if let room = try? buffer.readString(), let count = try? buffer.readUInt32() {
                var tickers: [RoomTicker] = []
                for _ in 0 ..< count {
                    if let user = try? buffer.readString(), let msg = try? buffer.readString() {
                        tickers.append(RoomTicker(username: user, message: msg))
                    }
                }
                chat.setTickers(room: room, tickers: tickers)
                chatRevision += 1
            }
        case ServerCode.roomTickerAdded:
            if let room = try? buffer.readString(),
               let user = try? buffer.readString(),
               let msg = try? buffer.readString() {
                chat.tickerAdded(room: room, ticker: RoomTicker(username: user, message: msg))
                chatRevision += 1
            }
        case ServerCode.roomTickerRemoved:
            if let room = try? buffer.readString(), let user = try? buffer.readString() {
                chat.tickerRemoved(room: room, username: user)
                chatRevision += 1
            }
        case ServerCode.excludedSearchPhrases:
            if let count = try? buffer.readUInt32() {
                var phrases: [String] = []
                for _ in 0 ..< count {
                    if let phrase = try? buffer.readString() {
                        phrases.append(phrase)
                    }
                }
                shares.excludedPhrases = phrases
                search.setExcludedPhrases(phrases)
            }
        case ServerCode.cantConnectToPeer:
            let token = (try? buffer.readUInt32()) ?? 0
            peerManager.handleCantConnect(token: token)
        case ServerCode.cantCreateRoom:
            if let room = try? buffer.readString() {
                chat.addPrivateMessage(username: "Server", text: "Cannot create room '\(room)'", isSelf: false)
                chatRevision += 1
            }
        case ServerCode.resetDistributed:
            peerManager.rejectParentCandidates()
            distributed.reset()
            updateAcceptChildren()
        case ServerCode.changePassword:
            if let password = try? buffer.readString() {
                config.password = password
                saveConfig()
            }
        case ServerCode.roomMembers:
            if let room = try? buffer.readString(), let count = try? buffer.readUInt32() {
                var members = Set<String>()
                for _ in 0 ..< count {
                    if let user = try? buffer.readString() {
                        members.insert(user)
                    }
                }
                chat.room(named: room)?.members = members
                chatRevision += 1
            }
        case ServerCode.addRoomMember, ServerCode.removeRoomMember:
            if let room = try? buffer.readString(), let user = try? buffer.readString() {
                chat.addPrivateMessage(username: "Server",
                                       text: "\(user) was \(code == ServerCode.addRoomMember ? "added to" : "removed from") \(room)",
                                       isSelf: false)
                chatRevision += 1
            }
        case ServerCode.roomMembershipGranted:
            if let room = try? buffer.readString() {
                chat.joinedOrNewRoom(named: room, isPrivate: true)
                chatRevision += 1
            }
        case ServerCode.roomMembershipRevoked:
            if let room = try? buffer.readString() {
                chat.leaveRoom(named: room)
                chatRevision += 1
            }
        case ServerCode.roomOperators:
            if let room = try? buffer.readString(), let count = try? buffer.readUInt32() {
                var operators = Set<String>()
                for _ in 0 ..< count {
                    if let user = try? buffer.readString() {
                        operators.insert(user)
                    }
                }
                chat.room(named: room)?.operators = operators
                chatRevision += 1
            }
        case ServerCode.addRoomOperator, ServerCode.removeRoomOperator:
            if let room = try? buffer.readString(), let user = try? buffer.readString() {
                chat.addPrivateMessage(username: "Server",
                                       text: "\(user) operator status \(code == ServerCode.addRoomOperator ? "granted in" : "revoked in") \(room)",
                                       isSelf: false)
                chatRevision += 1
            }
        case ServerCode.roomOperatorshipGranted:
            if let room = try? buffer.readString() {
                chat.room(named: room)?.operators.insert(loggedInUsername ?? "")
                chatRevision += 1
            }
        case ServerCode.roomOperatorshipRevoked:
            if let room = try? buffer.readString() {
                chat.room(named: room)?.operators.remove(loggedInUsername ?? "")
                chatRevision += 1
            }
        case ServerCode.globalRoomMessage:
            if let room = try? buffer.readString(),
               let user = try? buffer.readString(),
               let message = try? buffer.readString() {
                chat.addGlobalFeedMessage(room: room, username: user, text: message)
                chatRevision += 1
            }
        default:
            break
        }
    }

    // MARK: - Server message handlers

    private func handleLogin(_ buffer: inout MessageBuffer) {
        guard let success = try? buffer.readBool() else { return }

        if !success {
            let reason = (try? buffer.readString()) ?? "Unknown reason"
            let detail = try? buffer.readString()
            connectionState = .failed(detail.map { "\(reason): \($0)" } ?? reason)
            serverStream?.close()
            return
        }

        let banner = (try? buffer.readString()) ?? ""
        _ = try? buffer.readIPAddress()
        _ = try? buffer.readString() // password checksum echo
        _ = try? buffer.readBool()   // is_supporter

        connectionState = .loggedIn
        loggedInUsername = config.username
        peerManager.localUsername = config.username
        distributed.localUsername = config.username
        serverBanner = banner
        reconnectAttempts = 0

        // Post-login sequence (mirrors Nicotine+).
        peerManager.startListening(port: config.listenPort)
        listenPort = peerManager.boundPort
        send(ServerOut.setWaitPort(UInt32(peerManager.boundPort)))
        send(ServerOut.checkPrivileges())
        distributed.announceInitialState()
        updateAcceptChildren()
        send(ServerOut.roomListRequest())
        for buddy in config.buddies {
            watchUser(buddy)
        }
        watchUser(config.username)
        send(ServerOut.getUserStats(config.username))
        for username in Set(transfers.downloads.filter { $0.status == .userOffline }.map(\.username)) {
            watchUser(username)
        }
        for room in Set(config.autoJoinRooms + chat.joinedRooms.map(\.name)).sorted() {
            joinRoom(room, isPrivate: chat.room(named: room)?.isPrivate ?? false)
        }
        for item in config.likes { send(ServerOut.addThingILike(item)) }
        for item in config.hates { send(ServerOut.addThingIHate(item)) }
        isAway = config.away
        send(ServerOut.setStatus(isAway ? UserStatusValue.away : UserStatusValue.online))
        publishSharedCounts()
        startPingTimer()

        // Rescan shares now that we know where downloads go.
        transfers.downloadDirectory = downloadDirectory
        rescanShares()
    }

    private func handleWatchUser(_ buffer: inout MessageBuffer) {
        guard let user = try? buffer.readString(),
              let exists = try? buffer.readBool() else { return }
        var info = users[user] ?? UserInfo()
        guard exists else {
            info.status = UserStatusValue.offline
            users[user] = info
            transfers.handleUserWentOffline(user)
            transferRevision += 1
            return
        }
        if let status = try? buffer.readUInt32(),
           let avgSpeed = try? buffer.readUInt32(),
           let uploads = try? buffer.readUInt32(),
           let _ = try? buffer.readUInt32(),
           let files = try? buffer.readUInt32(),
           let dirs = try? buffer.readUInt32() {
            info.status = status
            info.stats.avgSpeed = avgSpeed
            info.stats.uploads = uploads
            info.stats.sharedFiles = files
            info.stats.sharedFolders = dirs
            if let country = try? buffer.readString() {
                info.country = country
            }
            users[user] = info
            if status == UserStatusValue.offline { transfers.handleUserWentOffline(user) }
            else { transfers.handleUserOnline(user) }
        }
        transferRevision += 1
    }

    private func handleJoinRoom(_ buffer: inout MessageBuffer) {
        guard let room = try? buffer.readString() else { return }
        var usernames: [String] = []
        var statuses: [UInt32] = []
        var stats: [(UInt32, UInt32, UInt32, UInt32, UInt32)] = []
        var slots: [UInt32] = []
        var countries: [String] = []

        if let count = try? buffer.readUInt32() {
            for _ in 0 ..< count {
                if let name = try? buffer.readString() { usernames.append(name) }
            }
        }
        if let count = try? buffer.readUInt32() {
            for _ in 0 ..< count {
                if let status = try? buffer.readUInt32() { statuses.append(status) }
            }
        }
        if let count = try? buffer.readUInt32() {
            for _ in 0 ..< count {
                if let a = try? buffer.readUInt32(), let b = try? buffer.readUInt32(),
                   let c = try? buffer.readUInt32(), let d = try? buffer.readUInt32(),
                   let e = try? buffer.readUInt32() {
                    stats.append((a, b, c, d, e))
                }
            }
        }
        if let count = try? buffer.readUInt32() {
            for _ in 0 ..< count {
                if let slot = try? buffer.readUInt32() { slots.append(slot) }
            }
        }
        if let count = try? buffer.readUInt32() {
            for _ in 0 ..< count {
                if let country = try? buffer.readString() { countries.append(country) }
            }
        }

        var owner: String?
        var operators: [String] = []
        var isPrivate = false
        if !buffer.isAtEnd {
            isPrivate = true
            owner = try? buffer.readString()
            if let opCount = try? buffer.readUInt32() {
                for _ in 0 ..< opCount {
                    if let op = try? buffer.readString() {
                        operators.append(op)
                    }
                }
            }
        }

        for (index, user) in usernames.enumerated() {
            var info = users[user] ?? UserInfo()
            if index < statuses.count { info.status = statuses[index] }
            if index < stats.count {
                info.stats.avgSpeed = stats[index].0
                info.stats.uploads = stats[index].1
                info.stats.sharedFiles = stats[index].3
                info.stats.sharedFolders = stats[index].4
            }
            if index < countries.count { info.country = countries[index] }
            users[user] = info
        }

        chat.setRoomUsers(room: room, users: usernames, owner: owner, operators: operators, isPrivate: isPrivate)
        chatRevision += 1
    }

    private func handleRoomList(_ buffer: inout MessageBuffer) {
        func parseRooms(withCounts: Bool) -> [(String, UInt32?)] {
            var result: [(String, UInt32?)] = []
            guard let count = try? buffer.readUInt32() else { return result }
            var names: [String] = []
            for _ in 0 ..< count {
                if let name = try? buffer.readString() { names.append(name) }
            }
            if withCounts, let userCount = try? buffer.readUInt32() {
                var counts: [UInt32] = []
                for _ in 0 ..< userCount { counts.append((try? buffer.readUInt32()) ?? 0) }
                for (index, name) in names.enumerated() {
                    result.append((name, index < counts.count ? counts[index] : nil))
                }
            } else {
                for name in names { result.append((name, nil)) }
            }
            return result
        }

        let publicRooms = parseRooms(withCounts: true)
        let ownedRooms = parseRooms(withCounts: true)
        let memberRooms = parseRooms(withCounts: true)
        let operatorRooms = parseRooms(withCounts: false)

        var counts = roomCounts
        for room in publicRooms + ownedRooms + memberRooms {
            chat.updateRoomList([(room.0, 0)])
            if let count = room.1 {
                counts[room.0] = count
            }
        }
        roomCounts = counts
        for (name, _) in operatorRooms {
            chat.updateRoomList([(name, 0)])
        }
        chatRevision += 1
    }

    private func handleEmbeddedMessage(_ buffer: inout MessageBuffer) {
        guard let distribCode = try? buffer.readByte() else { return }
        // We received this because we are a branch root.
        distributed.becomeBranchRoot()

        if distribCode == DistribCode.distribSearch.rawValue {
            let body = MessageBuffer(bytes: buffer.readRemaining())
            if let forwarded = distributed.handleDistribMessage(code: distribCode, body: body,
                                                                from: "server", connectionID: 0,
                                                                isParentCandidate: false) {
                peerManager.sendToDistributedChildren(Frame.distributed(code: distribCode, payload: forwarded))
            }
        }
    }

    private func handlePossibleParents(_ buffer: inout MessageBuffer) {
        guard let count = try? buffer.readUInt32() else { return }
        var candidates: [(String, String, UInt16)] = []
        for _ in 0 ..< count {
            if let username = try? buffer.readString(),
               let host = try? buffer.readIPAddress(),
               let port = try? buffer.readUInt32() {
                candidates.append((username, host, UInt16(clamping: port)))
            }
        }
        distributed.handlePossibleParents(
            candidates.map { (username: $0.0, host: $0.1, port: $0.2) },
            connect: { [weak self] username, host, port in
                self?.peerManager.connectToParentCandidate(username: username, host: host, port: port)
            }
        )
    }

    private func readStringList(_ buffer: inout MessageBuffer) throws -> [String] {
        let count = try buffer.readUInt32()
        guard count <= buffer.remaining / 4 else { throw SlskError.truncated("string list") }
        return try (0..<count).map { _ in try buffer.readString() }
    }

    private func parseRecommendations(_ buffer: inout MessageBuffer, isItem: Bool = false) {
        var recommendations: [Recommendation] = []
        var unrecommendations: [Recommendation] = []

        func parseList() {
            guard let count = try? buffer.readUInt32() else { return }
            for _ in 0 ..< count {
                if let item = try? buffer.readString(), let score = try? buffer.readInt32() {
                    if score >= 0 {
                        recommendations.append(Recommendation(item: item, score: score))
                    } else {
                        unrecommendations.append(Recommendation(item: item, score: score))
                    }
                }
            }
        }
        parseList()
        if !buffer.isAtEnd { parseList() }

        if !isItem {
            self.recommendations = recommendations
            self.unrecommendations = unrecommendations
        } else {
            // Item recommendations reuse the same parser.
            self.itemRecommendations = recommendations
        }
    }

    private struct ParsedUserData {
        var status: UInt32
        var stats: UserStats
        var country: String?
    }

    private func parseUserData(_ buffer: inout MessageBuffer) throws -> ParsedUserData {
        let status = try buffer.readUInt32()
        var stats = UserStats()
        stats.avgSpeed = try buffer.readUInt32()
        stats.uploads = try buffer.readUInt32()
        _ = try buffer.readUInt32() // unknown
        stats.sharedFiles = try buffer.readUInt32()
        stats.sharedFolders = try buffer.readUInt32()
        _ = try buffer.readUInt32() // slots full
        let country = try? buffer.readString()
        return ParsedUserData(status: status, stats: stats, country: country)
    }

    // MARK: - Incoming search requests (server + distributed)

    private func handleIncomingSearch(username: String, token: UInt32, query: String, connectionID: UInt64?) {
        guard !config.bannedUsers.contains(username), !username.isEmpty else { return }
        let parsed = SearchQuery(query)
        guard !parsed.includedWords.isEmpty else { return }
        let results = shares.search(query: parsed)
        guard !results.isEmpty else { return }

        var b = MessageBuffer()
        b.writeString(loggedInUsername ?? "")
        b.writeUInt32(token)
        b.writeUInt32(UInt32(results.count))
        for file in results {
            FileListCodec.packFileInfo(file, into: &b)
        }
        let slotsFree = transfers.activeUploadCount < transfers.uploadSlots
        b.writeBool(slotsFree)
        b.writeUInt32(distributed.uploadSpeed)
        b.writeUInt32(UInt32(transfers.queuedUploadCount))
        b.writeUInt32(0)

        guard let payload = try? Zlib.compress(b.data) else { return }
        let response = Frame.peer(code: PeerCode.fileSearchResponse, payload: [UInt8](payload))

        // Nicotine+ search.py sends FileSearchResponse to the searcher, never to the D parent.
        peerManager.sendToPeer(username, response)
    }

    // MARK: - Timers

    private func startPingTimer() {
        pingTimer?.invalidate()
        let timer = Timer(fire: Date().addingTimeInterval(60), interval: 60, repeats: true) { [weak self] _ in
            guard let self, self.isLoggedIn else { return }
            self.send(ServerOut.serverPing())
        }
        RunLoop.main.add(timer, forMode: .default)
        pingTimer = timer
    }

    private func updateAcceptChildren() {
        let accepts = distributed.children.count < distributed.maxChildren
        send(ServerOut.acceptChildren(accepts))
    }

    // MARK: - Public API used by the SwiftUI layer

    public var downloadDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return documents.appendingPathComponent(config.downloadFolderName)
    }

    public func setDownloadFolderName(_ name: String) {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              transfers.downloads.allSatisfy({ $0.status == .finished || $0.status == .cancelled }) else { return }
        config.downloadFolderName = name
        transfers.downloadDirectory = downloadDirectory
        saveConfig()
    }

    public func rescanShares() {
        shares.rescan { [weak self] in
            guard let self else { return }
            self.sharesRevision += 1
            self.publishSharedCounts()
        }
    }

    public func setSharedDirectories(_ urls: [URL]) {
        shares.setSharedDirectories(urls)
        config.shareFolderNames = urls.map { $0.lastPathComponent }
        saveConfig()
        rescanShares()
    }

    private func publishSharedCounts() {
        guard isLoggedIn else { return }
        send(ServerOut.sharedFoldersFiles(folders: shares.sharedFolderCount, files: shares.sharedFileCount))
    }

    public func watchUser(_ username: String) {
        guard !username.isEmpty else { return }
        send(ServerOut.watchUser(username))
    }

    public func unwatchUser(_ username: String) {
        send(ServerOut.unwatchUser(username))
        users[username] = nil
    }

    public func startSearch(_ text: String) {
        guard let session = search.startSearch(text), isLoggedIn else { return }
        send(ServerOut.fileSearch(token: session.token, query: session.query.rawText))
        searchRevision += 1
    }

    public func searchUser(_ username: String, query: String) {
        guard let session = search.startSearch(query), isLoggedIn else { return }
        send(ServerOut.userSearch(username: username, token: session.token, query: session.query.rawText))
    }

    public func searchRoom(_ room: String, query: String) {
        guard let session = search.startSearch(query), isLoggedIn else { return }
        send(ServerOut.roomSearch(room: room, token: session.token, query: session.query.rawText))
    }

    public func download(file: RemoteFileInfo, from username: String) {
        transfers.addDownload(username: username, file: file)
    }

    public func downloadFolder(_ folder: String, files: [RemoteFileInfo], from username: String) {
        transfers.addFolderDownloads(username: username, folder: folder, files: files)
    }

    public func joinRoom(_ name: String, isPrivate: Bool = false) {
        guard isLoggedIn else { return }
        _ = chat.joinedOrNewRoom(named: name, isPrivate: isPrivate)
        send(ServerOut.joinRoom(name, isPrivate: isPrivate))
        chatRevision += 1
    }

    public func leaveRoom(_ name: String) {
        send(ServerOut.leaveRoom(name))
        chat.leaveRoom(named: name)
        chatRevision += 1
    }

    public func say(room: String, _ text: String) {
        send(ServerOut.sayChatroom(room: room, message: text))
    }

    public func sendMessage(to username: String, _ text: String) {
        send(ServerOut.messageUser(username: username, message: text))
        chat.addPrivateMessage(username: username, text: text, isSelf: true)
        chatRevision += 1
    }

    public func browseUser(_ username: String) {
        guard isLoggedIn else { return }
        browseSessions[username] = BrowseSession(username: username)
        peerManager.sendToPeer(username, PeerOut.sharedFileListRequest())
        browseRevision += 1
    }

    public func browseSession(for username: String) -> BrowseSession? {
        browseSessions[username]
    }

    public func requestUserInfo(_ username: String, completion: ((String, PeerUserInfo) -> Void)? = nil) {
        guard isLoggedIn else { return }
        userInfoHandlers[username] = completion
        peerManager.sendToPeer(username, PeerOut.userInfoRequest())
    }

    public func requestUserInterests(_ username: String) {
        send(ServerOut.userInterestsRequest(username))
    }

    public func requestFolderContents(username: String, folder: String,
                                      completion: @escaping ([String: [RemoteFileInfo]]) -> Void) {
        guard isLoggedIn else { return }
        let token = folderTokens.next()
        folderContentsHandlers[token] = completion
        peerManager.sendToPeer(username, PeerOut.folderContentsRequest(token: token, directory: folder))
    }

    public func setAway(_ away: Bool) {
        isAway = away
        config.away = away
        saveConfig()
        send(ServerOut.setStatus(away ? UserStatusValue.away : UserStatusValue.online))
    }

    public func addBuddy(_ username: String) {
        guard !config.buddies.contains(username) else { return }
        config.buddies.append(username)
        saveConfig()
        watchUser(username)
    }

    public func removeBuddy(_ username: String) {
        config.buddies.removeAll { $0 == username }
        saveConfig()
        unwatchUser(username)
    }

    public func banUser(_ username: String) {
        if !config.bannedUsers.contains(username) { config.bannedUsers.append(username) }
        saveConfig()
        // Drop any queued uploads for this user.
        for item in transfers.uploads where item.username == username && item.status == .queued {
            item.status = .failed(TransferRejectReason.banned)
        }
        transferRevision += 1
    }

    public func unbanUser(_ username: String) {
        config.bannedUsers.removeAll { $0 == username }
        saveConfig()
    }

    public func ignoreUser(_ username: String) {
        if !config.ignoredUsers.contains(username) { config.ignoredUsers.append(username) }
        saveConfig()
    }

    public func unignoreUser(_ username: String) {
        config.ignoredUsers.removeAll { $0 == username }
        saveConfig()
    }

    public func addLike(_ item: String) {
        guard !config.likes.contains(item) else { return }
        config.likes.append(item)
        saveConfig()
        send(ServerOut.addThingILike(item))
    }

    public func removeLike(_ item: String) {
        config.likes.removeAll { $0 == item }
        saveConfig()
        send(ServerOut.removeThingILike(item))
    }

    public func addHate(_ item: String) {
        guard !config.hates.contains(item) else { return }
        config.hates.append(item)
        saveConfig()
        send(ServerOut.addThingIHate(item))
    }

    public func removeHate(_ item: String) {
        config.hates.removeAll { $0 == item }
        saveConfig()
        send(ServerOut.removeThingIHate(item))
    }

    public func requestRecommendations() {
        send(ServerOut.recommendationsRequest())
    }

    public func requestGlobalRecommendations() {
        send(ServerOut.globalRecommendationsRequest())
    }

    public func requestSimilarUsers() {
        send(ServerOut.similarUsersRequest())
    }

    public func requestItemRecommendations(_ item: String) {
        send(ServerOut.itemRecommendationsRequest(item))
    }

    public func requestItemSimilarUsers(_ item: String) {
        send(ServerOut.itemSimilarUsersRequest(item))
    }

    public func setWishlist(_ items: [String]) {
        config.wishlist = items
        saveConfig()
        search.setWishlist(items)
    }

    public func setRoomTicker(room: String, message: String) {
        send(ServerOut.setRoomTicker(room: room, message: message))
    }

    public func createPrivateRoom(_ name: String) {
        joinRoom(name, isPrivate: true)
    }

    public func addPrivateRoomMember(room: String, username: String) {
        send(ServerOut.addRoomMember(room: room, username: username))
    }

    public func removePrivateRoomMember(room: String, username: String) {
        send(ServerOut.removeRoomMember(room: room, username: username))
    }

    public func addPrivateRoomOperator(room: String, username: String) {
        send(ServerOut.addRoomOperator(room: room, username: username))
    }

    public func removePrivateRoomOperator(room: String, username: String) {
        send(ServerOut.removeRoomOperator(room: room, username: username))
    }

    public func cancelPrivateRoomMembership(room: String) {
        send(ServerOut.cancelRoomMembership(room: room))
        chat.leaveRoom(named: room)
        chatRevision += 1
    }

    public func joinGlobalRoomFeed() {
        guard isLoggedIn else { return }
        isGlobalRoomFeedEnabled = true
        send(ServerOut.joinGlobalRoom())
    }

    public func leaveGlobalRoomFeed() {
        isGlobalRoomFeedEnabled = false
        send(ServerOut.leaveGlobalRoom())
        chat.clearGlobalRoomMessages()
        chatRevision += 1
    }

    public func changePassword(_ password: String) {
        send(ServerOut.changePassword(password))
    }

    public func givePrivileges(to username: String, days: UInt32) {
        send(ServerOut.givePrivileges(username: username, days: days))
    }

    public func checkPrivileges() {
        send(ServerOut.checkPrivileges())
    }

    public func saveAll() {
        saveConfig()
        chat.saveHistory(storage: storage)
        transfers.persist()
    }

    /// Build our own UserInfoResponse payload for UserInfoRequest peers.
    func buildUserInfoResponse(totalUploads: UInt32, queueSize: UInt32) -> Data {
        PeerOut.userInfoResponse(description: config.userInfoDescription,
                                 picture: nil,
                                 totalUploads: totalUploads,
                                 queueSize: queueSize,
                                 slotsAvailable: transfers.activeUploadCount < transfers.uploadSlots,
                                 uploadAllowed: 1)
    }
}

// MARK: - ByteStreamDelegate (server)

extension SoulseekClient: ByteStreamDelegate {
    public func byteStreamDidOpen(_ stream: any ByteStream) {
        if stream === serverStream {
            handleServerOpen()
        }
    }

    public func byteStream(_ stream: any ByteStream, didReceive data: Data) {
        guard stream === serverStream else { return }
        do {
            serverAssembler.append(data)
            while let body = try serverAssembler.nextFrame() {
                handleServerFrame(body)
                guard stream === serverStream else { return }
            }
        } catch {
            disconnect()
        }
    }

    public func byteStream(_ stream: any ByteStream, didCloseWith error: (any Error)?) {
        if stream === serverStream {
            handleServerClosed(error)
        }
    }
}

// MARK: - PeerConnectionManagerDelegate

extension SoulseekClient: PeerConnectionManagerDelegate {
    public func peerManager(_ manager: PeerConnectionManager, didReceivePeerMessageCode code: UInt32,
                            body: MessageBuffer, from username: String) {
        var buffer = body

        switch code {
        case PeerCode.sharedFileListRequest:
            if let data = try? shares.browseResponseData() {
                manager.sendToPeer(username, Frame.peer(code: PeerCode.sharedFileListResponse,
                                                        payload: [UInt8](data)))
            }
        case PeerCode.sharedFileListResponse:
            handleBrowseResponse(username: username, buffer: &buffer)
        case PeerCode.fileSearchResponse:
            guard let decompressed = try? Zlib.decompress(Data(buffer.readRemaining()),
                                                          maxOutput: 128 * 1024 * 1024) else { return }
            try? search.handleSearchResponse(username: username, body: MessageBuffer(decompressed),
                                             isBanned: { [weak self] in self?.config.bannedUsers.contains($0) ?? false })
        case PeerCode.userInfoRequest:
            manager.sendToPeer(username, buildUserInfoResponse(totalUploads: UInt32(max(1, transfers.uploadSlots)),
                                                               queueSize: UInt32(transfers.queuedUploadCount)))
        case PeerCode.userInfoResponse:
            handleUserInfoResponse(username: username, buffer: &buffer)
        case PeerCode.folderContentsRequest:
            if let token = try? buffer.readUInt32(), let folder = try? buffer.readString(),
               let data = try? shares.folderContentsResponseData(token: token, folder: folder) {
                manager.sendToPeer(username, Frame.peer(code: PeerCode.folderContentsResponse,
                                                        payload: [UInt8](data)))
            }
        case PeerCode.folderContentsResponse:
            handleFolderContentsResponse(buffer: &buffer)
        case PeerCode.transferRequest:
            if let direction = try? buffer.readUInt32(),
               let token = try? buffer.readUInt32(),
               let file = try? buffer.readString() {
                let fileSize = try? buffer.readUInt64()
                let reply: Data?
                if direction == TransferDirection.upload {
                    reply = transfers.handleTransferRequest(direction: direction, token: token,
                                                            file: file, fileSize: fileSize, from: username)
                } else {
                    reply = transfers.handleLegacyDownloadRequest(token: token, file: file, from: username)
                }
                if let reply {
                    manager.sendToPeer(username, reply)
                }
            }
        case PeerCode.transferResponse:
            if let token = try? buffer.readUInt32(),
               let allowed = try? buffer.readBool() {
                if allowed {
                    transfers.handleTransferResponse(token: token, allowed: true, reason: nil, from: username)
                } else if let reason = try? buffer.readString() {
                    transfers.handleTransferResponse(token: token, allowed: false, reason: reason, from: username)
                }
            }
        case PeerCode.queueUpload:
            if let file = try? buffer.readString() {
                if let reply = transfers.handleQueueUpload(file: file, from: username) {
                    manager.sendToPeer(username, reply)
                }
            }
        case PeerCode.placeInQueueResponse:
            if let file = try? buffer.readString(), let place = try? buffer.readUInt32() {
                transfers.handlePlaceInQueueResponse(file: file, place: place, from: username)
            }
        case PeerCode.placeInQueueRequest:
            if let file = try? buffer.readString() {
                if let reply = transfers.handlePlaceInQueueRequest(file: file, from: username) {
                    manager.sendToPeer(username, reply)
                }
            }
        case PeerCode.uploadFailed:
            if let file = try? buffer.readString() {
                transfers.handleUploadFailed(file: file, from: username)
            }
        case PeerCode.uploadDenied:
            if let file = try? buffer.readString(), let reason = try? buffer.readString() {
                transfers.handleUploadDenied(file: file, reason: reason, from: username)
            }
        default:
            break
        }
        transferRevision += 1
    }

    public func peerManager(_ manager: PeerConnectionManager, didReceiveDistribCode code: UInt8,
                            body: MessageBuffer, from username: String, connectionID: UInt64) {
        let forwarded = distributed.handleDistribMessage(code: code, body: body, from: username,
                                                         connectionID: connectionID,
                                                         isParentCandidate: distributed.parentCandidates.contains { $0.username == username })
        if let forwarded {
            manager.sendToDistributedChildren(Frame.distributed(code: code, payload: forwarded))
        }
    }

    public func peerManager(_ manager: PeerConnectionManager, didOpenDownloadConnection id: UInt64,
                            username: String, token: UInt32) {
        transfers.handleDownloadConnectionOpened(connectionID: id, username: username, token: token)
    }

    public func peerManager(_ manager: PeerConnectionManager, didOpenUploadConnection id: UInt64,
                            username: String, token: UInt32) {
        transfers.handleUploadConnectionOpened(connectionID: id, username: username, token: token)
    }

    public func peerManager(_ manager: PeerConnectionManager, didReceiveFileData id: UInt64, data: Data) {
        transfers.handleDownloadData(connectionID: id, data: data)
    }

    public func peerManager(_ manager: PeerConnectionManager, didReceiveUploadOffset id: UInt64, offset: UInt64) {
        transfers.handleUploadOffset(connectionID: id, offset: offset)
    }

    public func peerManager(_ manager: PeerConnectionManager, didCloseFileConnection id: UInt64,
                            error: (any Error)?) {
        transfers.handleDownloadConnectionClosed(connectionID: id, error: error)
        transfers.handleUploadConnectionClosed(connectionID: id, error: error)
    }

    public func peerManager(_ manager: PeerConnectionManager, didFailPeerConnection username: String) {
        transfers.handlePeerConnectionFailed(username)
    }

    public func peerManager(_ manager: PeerConnectionManager, distributedConnectionClosed username: String) {
        distributed.handleChildDisconnected(username)
    }

    public func peerManager(_ manager: PeerConnectionManager, didAcceptChildConnection id: UInt64,
                            username: String) {
        guard distributed.children.count < distributed.maxChildren else {
            manager.closeFileConnection(id)
            return
        }
        distributed.handleChildConnected(username, connectionID: id)
    }

    // MARK: Peer response parsing

    private func handleBrowseResponse(username: String, buffer: inout MessageBuffer) {
        guard let decompressed = try? Zlib.decompress(Data(buffer.readRemaining())) else { return }
        var b = MessageBuffer(decompressed)
        let session = browseSessions[username] ?? BrowseSession(username: username)
        browseSessions[username] = session

        guard let folderCount = try? b.readUInt32() else { return }
        for _ in 0 ..< folderCount {
            guard let folder = try? b.readString(),
                  let fileCount = try? b.readUInt32() else { return }
            if let files = try? FileListCodec.parseFiles(count: fileCount, from: &b, folder: folder) {
                session.folders[folder.replacingOccurrences(of: "/", with: "\\")] = files
            }
        }
        session.isComplete = true
        browseRevision += 1
    }

    private func handleUserInfoResponse(username: String, buffer: inout MessageBuffer) {
        var info = PeerUserInfo()
        guard let description = try? buffer.readString() else { return }
        info.description = description
        if let hasPicture = try? buffer.readBool(), hasPicture {
            let length = (try? buffer.readUInt32()) ?? 0
            if let bytes = try? buffer.readBytes(Int(length)) {
                info.picture = Data(bytes)
            }
        }
        info.totalUploads = (try? buffer.readUInt32()) ?? 0
        info.queueSize = (try? buffer.readUInt32()) ?? 0
        info.slotsAvailable = (try? buffer.readBool()) ?? false
        if buffer.remaining >= 4 {
            info.uploadAllowed = (try? buffer.readUInt32()) ?? 0
        }
        userInfoHandlers.removeValue(forKey: username)?(username, info)
        transferRevision += 1
    }

    private func handleFolderContentsResponse(buffer: inout MessageBuffer) {
        guard let decompressed = try? Zlib.decompress(Data(buffer.readRemaining())) else { return }
        var b = MessageBuffer(decompressed)
        guard let token = try? b.readUInt32(),
              let directory = try? b.readString(),
              let folderCount = try? b.readUInt32() else { return }

        var folders: [String: [RemoteFileInfo]] = [:]
        for _ in 0 ..< folderCount {
            guard let folder = try? b.readString(),
                  let fileCount = try? b.readUInt32() else { return }
            folders[folder.replacingOccurrences(of: "/", with: "\\")] = try? FileListCodec.parseFiles(count: fileCount, from: &b, folder: folder)
        }
        folderContentsHandlers[token]?(folders)
        folderContentsHandlers[token] = nil
        browseRevision += 1
    }
}

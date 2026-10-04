import Foundation

/// Chat rooms and private messages state.
public final class ChatManager {
    public private(set) var rooms: [Room] = []
    public private(set) var privateThreads: [String: [ChatMessage]] = [:] // username → messages
    public private(set) var globalRoomMessages: [ChatMessage] = []

    public var unreadPrivateCount: Int { privateThreads.values.reduce(0) { $0 + $1.filter { !$0.isSelf }.count } }

    private var nextMessageID: UInt64 = 1

    public init() {}

    public func room(named name: String) -> Room? {
        rooms.first { $0.name == name }
    }

    public var joinedRooms: [Room] {
        rooms.filter { $0.joined }
    }

    @discardableResult
    public func joinedOrNewRoom(named name: String, isPrivate: Bool = false) -> Room {
        if let room = room(named: name) {
            room.joined = true
            return room
        }
        let room = Room(name: name, isPrivate: isPrivate, joined: true)
        rooms.append(room)
        return room
    }

    public func leaveRoom(named name: String) {
        room(named: name)?.joined = false
    }

    public func updateRoomList(_ summaries: [(name: String, count: UInt32)]) {
        for summary in summaries {
            if let room = room(named: summary.name) {
                // Keep joined rooms; counts refreshed by RoomList messages.
                continue
            }
            rooms.append(Room(name: summary.name, isPrivate: false, joined: false))
        }
    }

    public func roomCounts(_ summaries: [(name: String, count: UInt32)]) -> [String: UInt32] {
        Dictionary(summaries.map { ($0.name, $0.count) }, uniquingKeysWith: { a, _ in a })
    }

    public func addRoomMessage(room: String, username: String, text: String, isSelf: Bool) {
        let target = joinedOrNewRoom(named: room)
        target.messages.append(ChatMessage(id: nextMessageID, username: username, text: text,
                                           timestamp: Date(), isSelf: isSelf))
        if target.messages.count > 500 {
            target.messages.removeFirst(target.messages.count - 500)
        }
    }

    public func userJoined(room: String, username: String) {
        joinedOrNewRoom(named: room).users.append(username)
    }

    public func userLeft(room: String, username: String) {
        guard let target = self.room(named: room) else { return }
        target.users.removeAll { $0 == username }
    }

    public func setRoomUsers(room: String, users: [String], owner: String?, operators: [String], isPrivate: Bool) {
        let target = joinedOrNewRoom(named: room, isPrivate: isPrivate)
        target.users = users
        target.owner = owner
        target.operators = Set(operators)
        target.isPrivate = isPrivate
    }

    public func setTickers(room: String, tickers: [RoomTicker]) {
        self.room(named: room)?.tickers = tickers
    }

    public func tickerAdded(room: String, ticker: RoomTicker) {
        guard let target = self.room(named: room) else { return }
        target.tickers.removeAll { $0.username == ticker.username }
        target.tickers.append(ticker)
    }

    public func tickerRemoved(room: String, username: String) {
        self.room(named: room)?.tickers.removeAll { $0.username == username }
    }

    // MARK: Private messages

    public func addPrivateMessage(username: String, text: String, isSelf: Bool, timestamp: Date = Date()) {
        var thread = privateThreads[username] ?? []
        thread.append(ChatMessage(id: nextMessageID, username: username, text: text,
                                  timestamp: timestamp, isSelf: isSelf))
        if thread.count > 500 {
            thread.removeFirst(thread.count - 500)
        }
        privateThreads[username] = thread
    }

    public func messages(for username: String) -> [ChatMessage] {
        privateThreads[username] ?? []
    }

    public func privateThreadsList() -> [String] {
        privateThreads.keys.sorted { (privateThreads[$0]?.last?.timestamp ?? .distantPast)
            > (privateThreads[$1]?.last?.timestamp ?? .distantPast) }
    }

    public func clearPrivateThread(username: String) {
        privateThreads[username] = nil
    }

    public func addGlobalFeedMessage(room: String, username: String, text: String) {
        globalRoomMessages.append(ChatMessage(id: nextMessageID, username: "\(username) [\(room)]",
                                              text: text, timestamp: Date(), isSelf: false))
        if globalRoomMessages.count > 300 {
            globalRoomMessages.removeFirst(globalRoomMessages.count - 300)
        }
    }

    public func clearGlobalRoomMessages() {
        globalRoomMessages.removeAll()
    }

    public func loadHistory(storage: Storage) {
        if let savedRooms = storage.load([Room].self, as: "rooms") {
            for room in savedRooms where room.joined {
                rooms.removeAll { $0.name == room.name }
                rooms.append(room)
            }
        }
        if let threads = storage.load([String: [ChatMessage]].self, as: "private-chat") {
            privateThreads = threads
        }
    }

    public func saveHistory(storage: Storage) {
        storage.save(rooms.filter { $0.joined }, as: "rooms")
        storage.save(privateThreads, as: "private-chat")
    }
}

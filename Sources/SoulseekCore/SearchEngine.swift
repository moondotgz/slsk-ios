import Foundation

/// One initiated search: its query, token, and incoming hits grouped per user.
public final class SearchSession: Identifiable {
    public let token: UInt32
    public let query: SearchQuery
    public let createdAt: Date
    public private(set) var hits: [SearchHit] = []
    /// Users we already accepted results from, for de-duplication.
    private var seenPaths = Set<String>()

    init(token: UInt32, query: SearchQuery) {
        self.token = token
        self.query = query
        createdAt = Date()
    }

    public func hits(inFolder folder: String) -> [SearchHit] {
        hits.filter { $0.file.folder == folder }
    }

    public func folders() -> [String] {
        Array(Set(hits.map { $0.file.folder })).sorted()
    }

    func add(hit: SearchHit, filter: SearchFilter) -> Bool {
        guard token == hit.token else { return false }
        let key = hit.username + "\\" + hit.file.virtualPath
        guard !seenPaths.contains(key) else { return false }
        if !filter.allows(hit) { return false }
        seenPaths.insert(key)
        hits.append(hit)
        return true
    }

    func removeResults(from username: String) {
        hits.removeAll { $0.username == username }
    }
}

/// Client-side result filtering (bitrate/size/free-slot), like Nicotine+'s
/// search filters.
public struct SearchFilter: Codable {
    public var minimumBitrate: UInt32 = 0
    public var minimumSize: UInt64 = 0
    public var maximumSize: UInt64 = 0
    public var freeSlotOnly: Bool = false
    public var ignoreBanned: Bool = true

    public init() {}

    func allows(_ hit: SearchHit) -> Bool {
        if freeSlotOnly, !hit.freeUploadSlot { return false }
        if minimumBitrate > 0, (hit.file.bitrate ?? 0) < minimumBitrate { return false }
        if minimumSize > 0, hit.file.size < minimumSize { return false }
        if maximumSize > 0, hit.file.size > maximumSize { return false }
        return true
    }
}

/// Owns active searches and the wishlist (saved searches re-issued on the
/// server-provided interval).
public final class SearchEngine {
    private(set) public var sessions: [UInt32: SearchSession] = [:]
    private(set) public var excludedPhrases: [String] = []
    public var filter = SearchFilter()

    private let tokens = TokenGenerator()
    private var wishlistInterval: TimeInterval = 600
    private var wishlistTimer: Timer?

    /// Called for every accepted result (already de-duplicated + filtered).
    public var onResultsChanged: ((SearchSession) -> Void)?
    /// Called when a search request arrives from the network and matches our shares.
    public var onIncomingSearchRequest: ((String, UInt32, String) -> Void)?

    public init() {}

    public var activeSessions: [SearchSession] {
        sessions.values.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func startSearch(_ text: String) -> SearchSession? {
        let query = SearchQuery(text)
        guard !query.includedWords.isEmpty else { return nil }
        let token = tokens.next()
        let session = SearchSession(token: token, query: query)
        sessions[token] = session
        return session
    }

    public func removeSession(token: UInt32) {
        sessions[token] = nil
    }

    public func removeAllSessions() {
        sessions.removeAll()
    }

    public func setExcludedPhrases(_ phrases: [String]) {
        excludedPhrases = phrases
    }

    /// Parse an incoming FileSearchResponse body (already zlib-decompressed).
    /// Layout (Nicotine+ `FileSearchResponse`): username, token, file list,
    /// free-slot bool, upload speed, queue length, [unknown], [private list].
    public func handleSearchResponse(username: String, body: MessageBuffer, isBanned: (String) -> Bool) throws {
        var buffer = body
        let remoteUsername = try buffer.readString()
        let token = try buffer.readUInt32()
        guard let session = sessions[token], !isBanned(remoteUsername) else { return }
        let fileCount = try buffer.readUInt32()
        let files = try FileListCodec.parseFiles(count: fileCount, from: &buffer)
        let freeSlot = (try? buffer.readBool()) ?? false
        let uploadSpeed = (try? buffer.readUInt32()) ?? 0
        let queueLength = (try? buffer.readUInt32()) ?? 0

        var added = false
        for file in files {
            let hit = SearchHit(
                id: "\(remoteUsername)|\(token)|\(file.virtualPath)",
                username: remoteUsername, token: token, file: file,
                freeUploadSlot: freeSlot, uploadSpeed: uploadSpeed,
                queueLength: queueLength, isLocked: false
            )
            if session.add(hit: hit, filter: filter) {
                added = true
            }
        }
        if added {
            onResultsChanged?(session)
        }
    }

    // MARK: Wishlist

    public func wishlistItems() -> [String] {
        wishlistTimer != nil ? savedWishlist : []
    }

    private var savedWishlist: [String] = []

    public func setWishlist(_ items: [String]) {
        savedWishlist = items
    }

    public func setWishlistInterval(_ seconds: UInt32) {
        wishlistInterval = max(60, TimeInterval(seconds))
        scheduleWishlist()
    }

    public func onWishlistSearch(_ handler: @escaping (UInt32, String) -> Void) {
        wishlistHandler = handler
    }

    private var wishlistHandler: ((UInt32, String) -> Void)?

    private func scheduleWishlist() {
        wishlistTimer?.invalidate()
        guard !savedWishlist.isEmpty else { return }
        let timer = Timer(fire: Date().addingTimeInterval(wishlistInterval), interval: wishlistInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            for item in self.savedWishlist {
                let token = self.tokens.next()
                self.wishlistHandler?(token, item)
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        wishlistTimer = timer
    }
}

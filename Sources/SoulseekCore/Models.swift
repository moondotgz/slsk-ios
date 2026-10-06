import Foundation

// MARK: - Users

public struct UserStats: Equatable, Codable {
    public var avgSpeed: UInt32 = 0
    public var uploads: UInt32 = 0
    public var sharedFiles: UInt32 = 0
    public var sharedFolders: UInt32 = 0
    public var freeUploadSlots: UInt32 = 0

    public init() {}
}

public struct UserInfo: Codable, Equatable {
    public var status: UInt32 = UserStatusValue.offline
    public var privileged: Bool = false
    public var country: String?
    public var stats = UserStats()

    public init() {}
}

// MARK: - Chat

public struct ChatMessage: Identifiable, Equatable, Codable {
    public let id: UInt64
    public let username: String
    public let text: String
    public let timestamp: Date
    public let isSelf: Bool
}

public struct RoomTicker: Equatable, Codable {
    public let username: String
    public let message: String
}

// MARK: - Transfers

public enum TransferStatus: Equatable, Codable {
    case queued
    case gettingAddress
    case connecting
    case remotelyQueued
    case transferring
    case finished
    case paused
    case filtered
    case userOffline
    case failed(String)
    case cancelled

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .gettingAddress: "Getting address"
        case .connecting: "Connecting"
        case .remotelyQueued: "Remotely queued"
        case .transferring: "Transferring"
        case .finished: "Finished"
        case .paused: "Paused"
        case .filtered: "Filtered"
        case .userOffline: "User logged off"
        case let .failed(reason): reason
        case .cancelled: "Cancelled"
        }
    }

    public var isActive: Bool {
        switch self {
        case .queued, .gettingAddress, .connecting, .remotelyQueued, .transferring:
            true
        default:
            false
        }
    }
}

/// Common observable transfer state, used by both downloads and uploads.
open class TransferItem: Identifiable, Codable {
    public let id: UUID
    public let username: String
    public let virtualPath: String
    public var size: UInt64
    public var bitrate: UInt32?

    public var status: TransferStatus = .queued
    public var currentOffset: UInt64 = 0
    public var speed: Double = 0
    public var queuePosition: UInt32 = 0
    public var queuePositionIsStale = false
    public var automaticResumePending = false
    public var startedAt: Date?

    init(username: String, virtualPath: String, size: UInt64, bitrate: UInt32? = nil) {
        id = UUID()
        self.username = username
        self.virtualPath = virtualPath
        self.size = size
        self.bitrate = bitrate
    }

    public var fileName: String {
        virtualPath.contains("\\")
            ? String(virtualPath[virtualPath.index(after: virtualPath.lastIndex(of: "\\")!)...])
            : virtualPath
    }

    public var folder: String {
        virtualPath.contains("\\")
            ? String(virtualPath[..<virtualPath.lastIndex(of: "\\")!])
            : ""
    }

    var lastByteOffset: UInt64 = 0
    var transferredTotal: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case id, username
        case virtualPath
        case size, bitrate
        case status
        case currentOffset
        case queuePosition
        case automaticResumePending
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(virtualPath, forKey: .virtualPath)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encode(status, forKey: .status)
        try container.encode(currentOffset, forKey: .currentOffset)
        try container.encode(queuePosition, forKey: .queuePosition)
        try container.encode(automaticResumePending, forKey: .automaticResumePending)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        virtualPath = try container.decode(String.self, forKey: .virtualPath)
        size = try container.decode(UInt64.self, forKey: .size)
        bitrate = try container.decodeIfPresent(UInt32.self, forKey: .bitrate)
        status = try container.decodeIfPresent(TransferStatus.self, forKey: .status) ?? .queued
        currentOffset = try container.decodeIfPresent(UInt64.self, forKey: .currentOffset) ?? 0
        queuePosition = try container.decodeIfPresent(UInt32.self, forKey: .queuePosition) ?? 0
        queuePositionIsStale = queuePosition > 0
        automaticResumePending = try container.decodeIfPresent(Bool.self, forKey: .automaticResumePending) ?? false
    }
}

public final class DownloadItem: TransferItem {
    public var localFilePath: String?
}

public final class UploadItem: TransferItem {
    public var isPrivileged: Bool = false
}

// MARK: - Search

public struct SearchHit: Identifiable, Equatable {
    public let id: String
    public let username: String
    public let token: UInt32
    public let file: RemoteFileInfo
    public let freeUploadSlot: Bool
    public let uploadSpeed: UInt32
    public let queueLength: UInt32
    public let isLocked: Bool
}

// MARK: - Rooms

public final class Room: Identifiable, Codable {
    public let name: String
    public var isPrivate: Bool
    public var joined: Bool
    public var users: [String] = []
    public var owner: String?
    public var operators: Set<String> = []
    public var members: Set<String> = []
    public var tickers: [RoomTicker] = []
    public var messages: [ChatMessage] = []

    init(name: String, isPrivate: Bool = false, joined: Bool = false) {
        self.name = name
        self.isPrivate = isPrivate
        self.joined = joined
    }

    enum CodingKeys: String, CodingKey {
        case name, isPrivate, joined, messages
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encode(joined, forKey: .joined)
        try container.encode(Array(messages.suffix(200)), forKey: .messages)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        joined = try container.decodeIfPresent(Bool.self, forKey: .joined) ?? false
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
    }
}

public struct RoomSummary: Identifiable, Equatable, Codable {
    public var id: String { name }
    public let name: String
    public let userCount: UInt32
}

public struct Recommendation: Identifiable, Equatable, Codable {
    public var id: String { item }
    public let item: String
    public let score: Int32
}

// MARK: - User info response (from peers)

public struct UserInterestsInfo: Equatable {
    public let likes: [String]
    public let hates: [String]
}

public struct PeerUserInfo: Equatable {
    public var description: String = ""
    public var picture: Data?
    public var totalUploads: UInt32 = 0
    public var queueSize: UInt32 = 0
    public var slotsAvailable: Bool = false
    public var uploadAllowed: UInt32 = 0
    public var interests: [String] = []
    public var hates: [String] = []
}

// MARK: - Browse

public final class BrowseSession: Identifiable {
    public let username: String
    public var folders: [String: [RemoteFileInfo]] = [:]
    public var isComplete = false

    init(username: String) {
        self.username = username
    }

    public var folderNames: [String] {
        folders.keys.sorted()
    }
}

import Foundation

/// User-editable client configuration, persisted as JSON.
public struct ClientConfiguration: Codable {
    public var username: String = ""
    public var password: String = ""
    public var serverHost: String = "server.slsknet.org"
    public var serverPort: UInt16 = 2242
    public var listenPort: UInt16 = 2234

    public var downloadFolderName: String = "Downloads"
    public var uploadSlots: Int = 2
    public var maxDownloadConnections: Int = 8

    public var userInfoDescription: String = ""
    public var userInfoPictureName: String?

    public var away: Bool = false

    public var buddies: [String] = []
    public var bannedUsers: [String] = []
    public var ignoredUsers: [String] = []
    public var likes: [String] = []
    public var hates: [String] = []
    public var wishlist: [String] = []
    public var autoJoinRooms: [String] = []

    /// Virtual names of shared folders (mapped to security-scoped URLs by the
    /// app layer; Core only sees the resolved local paths).
    public var shareFolderNames: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case username, serverHost, serverPort, listenPort, downloadFolderName
        case uploadSlots, maxDownloadConnections, userInfoDescription, userInfoPictureName, away
        case buddies, bannedUsers, ignoredUsers, likes, hates, wishlist, autoJoinRooms, shareFolderNames
    }

    private enum LegacyKeys: String, CodingKey { case password }

    public init(from decoder: Decoder) throws {
        self.init()
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        password = try legacy.decodeIfPresent(String.self, forKey: .password) ?? ""
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? username
        serverHost = try c.decodeIfPresent(String.self, forKey: .serverHost) ?? serverHost
        serverPort = try c.decodeIfPresent(UInt16.self, forKey: .serverPort) ?? serverPort
        listenPort = try c.decodeIfPresent(UInt16.self, forKey: .listenPort) ?? listenPort
        downloadFolderName = try c.decodeIfPresent(String.self, forKey: .downloadFolderName) ?? downloadFolderName
        uploadSlots = try c.decodeIfPresent(Int.self, forKey: .uploadSlots) ?? uploadSlots
        maxDownloadConnections = try c.decodeIfPresent(Int.self, forKey: .maxDownloadConnections) ?? maxDownloadConnections
        userInfoDescription = try c.decodeIfPresent(String.self, forKey: .userInfoDescription) ?? userInfoDescription
        userInfoPictureName = try c.decodeIfPresent(String.self, forKey: .userInfoPictureName)
        away = try c.decodeIfPresent(Bool.self, forKey: .away) ?? away
        buddies = try c.decodeIfPresent([String].self, forKey: .buddies) ?? buddies
        bannedUsers = try c.decodeIfPresent([String].self, forKey: .bannedUsers) ?? bannedUsers
        ignoredUsers = try c.decodeIfPresent([String].self, forKey: .ignoredUsers) ?? ignoredUsers
        likes = try c.decodeIfPresent([String].self, forKey: .likes) ?? likes
        hates = try c.decodeIfPresent([String].self, forKey: .hates) ?? hates
        wishlist = try c.decodeIfPresent([String].self, forKey: .wishlist) ?? wishlist
        autoJoinRooms = try c.decodeIfPresent([String].self, forKey: .autoJoinRooms) ?? autoJoinRooms
        shareFolderNames = try c.decodeIfPresent([String].self, forKey: .shareFolderNames) ?? shareFolderNames
    }
}

public protocol PasswordStore: AnyObject {
    func password(for username: String) throws -> String?
    func savePassword(_ password: String, for username: String) throws
}

/// Loads/saves JSON documents inside a base directory.
public final class Storage {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    public func url(for name: String) -> URL {
        baseURL.appendingPathComponent(name).appendingPathExtension("json")
    }

    public func save<T: Encodable>(_ value: T, as name: String) {
        try? saveChecked(value, as: name)
    }

    public func saveChecked<T: Encodable>(_ value: T, as name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(value)
        try data.write(to: url(for: name), options: .atomic)
    }

    public func load<T: Decodable>(_ type: T.Type, as name: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}

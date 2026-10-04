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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        let target = url(for: name)
        let temp = target.deletingPathExtension().appendingPathExtension("tmp")
        try? data.write(to: temp, options: .atomic)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: temp, to: target)
    }

    public func load<T: Decodable>(_ type: T.Type, as name: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}

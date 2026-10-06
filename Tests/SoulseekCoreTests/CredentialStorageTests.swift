import Foundation
import XCTest
@testable import SoulseekCore

private final class TestPasswordStore: PasswordStore {
    var passwords: [String: String] = [:]
    var fails = false
    enum Failure: Error { case unavailable }

    func password(for username: String) throws -> String? {
        if fails { throw Failure.unavailable }
        return passwords[username]
    }

    func savePassword(_ password: String, for username: String) throws {
        if fails { throw Failure.unavailable }
        passwords[username] = password
    }
}

final class CredentialStorageTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slsk-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testEncodingNeverPersistsPasswordAndPreservesOtherConfiguration() throws {
        var config = ClientConfiguration()
        config.username = "tester"
        config.password = "secret-that-must-not-be-encoded"
        config.serverHost = "example.test"
        config.serverPort = 1234
        config.listenPort = 2345
        config.downloadFolderName = "Music"
        config.uploadSlots = 5
        config.maxDownloadConnections = 3
        config.userInfoDescription = "description"
        config.userInfoPictureName = "photo"
        config.away = true
        config.buddies = ["friend"]
        config.bannedUsers = ["banned"]
        config.ignoredUsers = ["ignored"]
        config.likes = ["like"]
        config.hates = ["hate"]
        config.wishlist = ["wish"]
        config.autoJoinRooms = ["room"]
        config.shareFolderNames = ["share"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["password"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(config.password))
        let decoded = try JSONDecoder().decode(ClientConfiguration.self, from: data)
        XCTAssertEqual(decoded.password, "")
        XCTAssertEqual(try encoder.encode(decoded), data)
    }

    func testLegacyPasswordMigratesAndReloadsFromSecureStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Storage(baseURL: directory)
        let legacy = Data(#"{"username":"tester","password":"legacy-secret","buddies":["friend"]}"#.utf8)
        try legacy.write(to: storage.url(for: "config"))
        let passwords = TestPasswordStore()
        let client = SoulseekClient(factory: MockTransportFactory(), storage: storage,
                                    config: ClientConfiguration(), passwordStore: passwords)
        defer { client.disconnect() }
        client.start()
        XCTAssertEqual(passwords.passwords["tester"], "legacy-secret")
        XCTAssertEqual(client.config.password, "legacy-secret")
        XCTAssertEqual(client.config.buddies, ["friend"])
        let clean = try Data(contentsOf: storage.url(for: "config"))
        XCTAssertFalse(String(decoding: clean, as: UTF8.self).contains("legacy-secret"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: clean) as? [String: Any])?["password"])
        let restored = SoulseekClient(factory: MockTransportFactory(), storage: storage,
                                      config: ClientConfiguration(), passwordStore: passwords)
        defer { restored.disconnect() }
        restored.start()
        XCTAssertEqual(restored.config.password, "legacy-secret")
        XCTAssertNil(restored.credentialStorageError)
    }

    func testFailedMigrationLeavesLegacyFileIntactAndCanBeRetried() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Storage(baseURL: directory)
        let legacy = Data(#"{"username":"tester","password":"legacy-secret"}"#.utf8)
        try legacy.write(to: storage.url(for: "config"))
        let passwords = TestPasswordStore()
        passwords.fails = true
        let client = SoulseekClient(factory: MockTransportFactory(), storage: storage,
                                    config: ClientConfiguration(), passwordStore: passwords)
        defer { client.disconnect() }
        client.start()
        XCTAssertNotNil(client.credentialStorageError)
        XCTAssertEqual(try Data(contentsOf: storage.url(for: "config")), legacy)
        XCTAssertFalse(client.saveConfig())
        XCTAssertEqual(try Data(contentsOf: storage.url(for: "config")), legacy)
        passwords.fails = false
        XCTAssertTrue(client.saveConfig())
        XCTAssertEqual(passwords.passwords["tester"], "legacy-secret")
        XCTAssertNil(client.credentialStorageError)
    }

    func testMigrationDoesNotOverwriteNewerSecurePasswordWithOldExport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Storage(baseURL: directory)
        try Data(#"{"username":"tester","password":"old-exported-secret"}"#.utf8)
            .write(to: storage.url(for: "config"))
        let passwords = TestPasswordStore()
        passwords.passwords["tester"] = "current-secret"
        let client = SoulseekClient(factory: MockTransportFactory(), storage: storage,
                                    config: ClientConfiguration(), passwordStore: passwords)
        defer { client.disconnect() }
        client.start()
        XCTAssertEqual(client.config.password, "current-secret")
        XCTAssertEqual(passwords.passwords["tester"], "current-secret")
        XCTAssertEqual(storage.load(ClientConfiguration.self, as: "config")?.password, "")
    }

    func testLoginAndPasswordUpdatesUsePerUserSecureEntries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Storage(baseURL: directory)
        let passwords = TestPasswordStore()
        passwords.passwords["other"] = "other-secret"
        let client = SoulseekClient(factory: MockTransportFactory(), storage: storage,
                                    config: ClientConfiguration(), passwordStore: passwords)
        defer { client.disconnect() }
        client.login(username: "tester", password: "first-secret")
        XCTAssertEqual(passwords.passwords["tester"], "first-secret")
        client.config.password = "changed-secret"
        XCTAssertTrue(client.saveConfig())
        XCTAssertEqual(passwords.passwords["tester"], "changed-secret")
        XCTAssertEqual(passwords.passwords["other"], "other-secret")
        XCTAssertEqual(storage.load(ClientConfiguration.self, as: "config")?.password, "")
    }

    func testKeychainFailurePreventsNewLoginAndPlaintextFallback() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Storage(baseURL: directory)
        let passwords = TestPasswordStore()
        passwords.fails = true
        let factory = MockTransportFactory()
        let client = SoulseekClient(factory: factory, storage: storage,
                                    config: ClientConfiguration(), passwordStore: passwords)
        defer { client.disconnect() }
        client.login(username: "tester", password: "new-secret")
        XCTAssertEqual(factory.serverStreams.count, 0)
        XCTAssertNotNil(client.credentialStorageError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.url(for: "config").path))
        XCTAssertFalse(client.connectionDiagnostics.joined().contains("new-secret"))
    }

    func testUnavailableSavedPasswordBlocksConnectRatherThanSendingEmptyLogin() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Storage(baseURL: directory)
        var config = ClientConfiguration()
        config.username = "tester"
        storage.save(config, as: "config")
        let factory = MockTransportFactory()
        let client = SoulseekClient(factory: factory, storage: storage,
                                    config: ClientConfiguration(), passwordStore: TestPasswordStore())
        defer { client.disconnect() }
        client.start()
        client.connect()
        XCTAssertEqual(factory.serverStreams.count, 0)
        XCTAssertEqual(client.connectionState, .failed("Saved password unavailable. Please log in again."))
    }
}

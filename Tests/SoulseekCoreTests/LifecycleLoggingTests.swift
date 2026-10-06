import Foundation
import XCTest
@testable import SoulseekCore

final class LifecycleLoggingTests: XCTestCase {
    private func storage() throws -> Storage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = Storage(baseURL: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return storage
    }

    private func client(storage: Storage) -> SoulseekClient {
        let client = SoulseekClient(factory: MockTransportFactory(), storage: storage,
                                    config: ClientConfiguration())
        client.start()
        return client
    }

    func testLifecycleLogsDeduplicatePhasesAndMeasureTimeAway() throws {
        let storage = try storage()
        let client = client(storage: storage)
        let date = Date(timeIntervalSince1970: 1_000)
        client.recordAppLifecycle(.active, now: date)
        client.recordAppLifecycle(.active, now: date.addingTimeInterval(1))
        client.recordAppLifecycle(.inactive, now: date.addingTimeInterval(2))
        client.recordAppLifecycle(.background, now: date.addingTimeInterval(3))
        client.recordAppLifecycle(.inactive, now: date.addingTimeInterval(60))
        client.recordAppLifecycle(.active, now: date.addingTimeInterval(63))

        XCTAssertEqual(client.connectionDiagnostics.count, 6)
        XCTAssertTrue(client.connectionDiagnostics.first?.contains("App lifecycle: launched") == true)
        XCTAssertTrue(client.connectionDiagnostics.last?.contains("timeAwaySeconds=60") == true)
        XCTAssertTrue(client.connectionDiagnostics.last?.contains("server=disconnected") == true)
        XCTAssertEqual(storage.load([String].self, as: "connection-log"), client.connectionDiagnostics)
        client.recordAppLifecycle(.inactive, now: date.addingTimeInterval(64))
        client.recordAppLifecycle(.active, now: date.addingTimeInterval(65))
        XCTAssertFalse(client.connectionDiagnostics.last?.contains("timeAwaySeconds") == true)
    }

    func testLifecycleSnapshotsDescribeTransfersWithoutChangingTheirState() throws {
        let storage = try storage()
        let client = client(storage: storage)
        client.config.password = "secret-not-for-logs"
        let item = try XCTUnwrap(client.transfers.addDownload(username: "peer",
            file: RemoteFileInfo(virtualPath: "private-file.bin", size: 8)))
        client.transfers.handlePeerConnectionFailed("peer")
        let status = item.status
        client.recordAppLifecycle(.background)
        client.recordAppLifecycle(.active)
        let event = try XCTUnwrap(client.connectionDiagnostics.last)
        XCTAssertTrue(event.contains("activePeers=0"))
        XCTAssertTrue(event.contains("downloading=0, uploading=0, pendingResume=1"))
        XCTAssertFalse(event.contains(item.virtualPath))
        XCTAssertFalse(client.connectionDiagnostics.joined().contains(client.config.password))
        XCTAssertEqual(item.status, status)
        XCTAssertEqual(client.connectionState, .disconnected)
    }

    func testLogSurvivesRelaunchAndClearAlsoClearsDisk() throws {
        let storage = try storage()
        let first = client(storage: storage)
        first.recordAppLifecycle(.background)
        let saved = first.connectionDiagnostics
        let second = client(storage: storage)
        XCTAssertEqual(Array(second.connectionDiagnostics.dropLast()), saved)
        XCTAssertTrue(second.connectionDiagnostics.last?.contains("App lifecycle: launched") == true)
        second.clearConnectionDiagnostics()
        XCTAssertTrue(second.connectionDiagnostics.isEmpty)
        XCTAssertEqual(storage.load([String].self, as: "connection-log"), [])
        let third = client(storage: storage)
        XCTAssertEqual(third.connectionDiagnostics.count, 1)
        XCTAssertFalse(third.connectionDiagnostics.joined().contains("background"))
    }

    func testMemoryWarningsAndRestoredLogsAreBounded() throws {
        let storage = try storage()
        storage.save((1...250).map { "old-event-\($0)" }, as: "connection-log")
        let client = client(storage: storage)
        XCTAssertEqual(client.connectionDiagnostics.count, 200)
        XCTAssertEqual(client.connectionDiagnostics.first, "old-event-52")
        for _ in 0..<220 { client.recordAppMemoryWarning() }
        XCTAssertEqual(client.connectionDiagnostics.count, 200)
        XCTAssertTrue(client.connectionDiagnostics.allSatisfy { $0.contains("App lifecycle: memory warning") })
        XCTAssertEqual(storage.load([String].self, as: "connection-log"), client.connectionDiagnostics)
    }

    func testSaveAllFlushesConnectionEventsSinceLastLifecycleChange() throws {
        let storage = try storage()
        let client = client(storage: storage)
        client.transfers.handleDownloadConnectionOpened(connectionID: 123, username: "unknown", token: 1)
        XCTAssertNotEqual(storage.load([String].self, as: "connection-log"), client.connectionDiagnostics)
        client.saveAll()
        XCTAssertEqual(storage.load([String].self, as: "connection-log"), client.connectionDiagnostics)
    }
}

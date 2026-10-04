import Foundation

/// Owns the download queue and the upload slots, implementing the modern
/// Nicotine+ transfer handshake:
///
/// Download: QueueUpload → (uploader) TransferRequest(upload) →
/// TransferResponse(allowed) → uploader opens 'F' connection →
/// FileTransferInit(token) → FileOffset → raw data.
///
/// Upload: QueueUpload → queue → TransferRequest(upload) →
/// TransferResponse(allowed) → open 'F' connection → FileTransferInit →
/// FileOffset → stream data.
public final class TransferManager {
    public private(set) var downloads: [DownloadItem] = []
    public private(set) var uploads: [UploadItem] = []

    public var gateway: (any PeerGateway)?
    public var shares: SharesManager?
    public var isBanned: (String) -> Bool = { _ in false }
    public var isIgnored: (String) -> Bool = { _ in false }
    public var onUploadFinishedSpeed: ((UInt32) -> Void)?
    public var onUserWatchRequested: ((String) -> Void)?
    public var onChanged: (() -> Void)?
    public var onDiagnostic: ((String) -> Void)?

    public var uploadSlots: Int = 2
    public var maxDownloadConnections: Int = 8
    public var downloadDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())

    private let tokens = TokenGenerator()
    // Nicotine+ downloads.active_users scopes uploader-generated tokens by username.
    private struct DownloadToken: Hashable {
        let username: String
        let token: UInt32
    }
    private var activeDownloads: [DownloadToken: DownloadItem] = [:]
    private var downloadConnections: [UInt64: DownloadItem] = [:]  // conn id → download
    private var activeUploads: [UInt32: UploadItem] = [:]          // token → upload
    private var uploadConnections: [UInt64: (upload: UploadItem, handle: FileHandle)] = [:]
    private var timeoutTimers: [UUID: Timer] = [:]
    private var uploadQueueTick: Timer?
    private var saveTimer: Timer?
    private var storage: Storage?
    var activationTimeout: TimeInterval = 45

    private static let chunkSize = 128 * 1024

    public init() {}

    public func configure(storage: Storage?, gateway: (any PeerGateway)?, shares: SharesManager?) {
        self.storage = storage
        self.gateway = gateway
        self.shares = shares
        loadPersisted()

        let timer = Timer(fire: Date().addingTimeInterval(60), interval: 60, repeats: true) { [weak self] _ in
            self?.queueMaintenanceTick()
        }
        RunLoop.main.add(timer, forMode: .default)
        uploadQueueTick = timer

        let saver = Timer(fire: Date().addingTimeInterval(30), interval: 30, repeats: true) { [weak self] _ in
            self?.persist()
        }
        RunLoop.main.add(saver, forMode: .default)
        saveTimer = saver
    }

    // MARK: - Downloads

    @discardableResult
    public func addDownload(username: String, file: RemoteFileInfo) -> DownloadItem? {
        guard !isIgnored(username) else { return nil }
        if downloads.contains(where: { $0.username == username && $0.virtualPath == file.virtualPath }) {
            return nil
        }
        let item = DownloadItem(username: username, virtualPath: file.virtualPath,
                                size: file.size, bitrate: file.bitrate)
        item.status = .queued
        downloads.append(item)
        onUserWatchRequested?(username)
        enqueueDownload(item)
        persist()
        return item
    }

    public func addFolderDownloads(username: String, folder: String, files: [RemoteFileInfo]) {
        for file in files.sorted(by: { $0.virtualPath < $1.virtualPath }) {
            addDownload(username: username, file: file)
        }
    }

    private func enqueueDownload(_ item: DownloadItem, recovering: Bool = false) {
        onDiagnostic?("Download \(recovering ? "recovering" : "queued"): peer=\(item.username), id=\(item.id), lastQueue=\(item.queuePosition)")
        item.status = .queued
        item.queuePositionIsStale = recovering && item.queuePosition > 0
        if !recovering { item.queuePosition = 0 }
        startTimeout(for: item)
        gateway?.sendToPeer(item.username, PeerOut.queueUpload(item.virtualPath))
        if item.status == .queued {
            gateway?.sendToPeer(item.username, PeerOut.placeInQueueRequest(item.virtualPath))
        }
        notifyChanged()
    }

    public func retryDownload(_ item: DownloadItem) {
        guard !item.status.isActive else { return }
        item.status = .queued
        enqueueDownload(item)
    }

    public func cancelDownload(_ item: DownloadItem) {
        if let token = activeDownloads.first(where: { $0.value === item })?.key {
            activeDownloads[token] = nil
        }
        if let connection = downloadConnections.first(where: { $0.value === item })?.key {
            gateway?.closeFileConnection(connection)
            downloadConnections[connection] = nil
        }
        timeoutTimers[item.id]?.invalidate()
        timeoutTimers[item.id] = nil
        item.status = .cancelled
        removePartialFile(for: item)
        persist()
        notifyChanged()
    }

    public func removeDownload(_ item: DownloadItem) {
        cancelDownload(item)
        downloads.removeAll { $0 === item }
        persist()
        notifyChanged()
    }

    public func clearFinishedDownloads() {
        downloads.removeAll { !$0.status.isActive && $0.status != .paused }
        persist()
        notifyChanged()
    }

    // MARK: Download event handlers (invoked by SoulseekClient)

    public func handlePlaceInQueueResponse(file: String, place: UInt32, from username: String) {
        guard let item = downloads.first(where: { $0.username == username && $0.virtualPath == file }),
              item.status == .queued || item.status == .remotelyQueued else { return }
        timeoutTimers[item.id]?.invalidate()
        timeoutTimers[item.id] = nil
        item.queuePosition = place
        item.queuePositionIsStale = false
        item.status = .remotelyQueued
        onDiagnostic?("Queue confirmed: peer=\(username), id=\(item.id), position=\(place)")
        notifyChanged()
    }

    public func handleUploadDenied(file: String, reason: String, from username: String) {
        guard let item = downloads.first(where: { $0.username == username && $0.virtualPath == file }),
              item.status.isActive else { return }
        deactivateDownload(item)
        item.status = .failed(reason)
        notifyChanged()
        persist()
    }

    public func handleUploadFailed(file: String, from username: String) {
        guard let item = downloads.first(where: { $0.username == username && $0.virtualPath == file }),
              item.status.isActive else { return }
        onDiagnostic?("UploadFailed from \(username): id=\(item.id), stage=\(item.status.label), bytes=\(item.currentOffset)/\(item.size)")
        deactivateDownload(item)
        item.status = .failed("Remote upload failed")
        notifyChanged()
        persist()
    }

    /// Uploader signals readiness (TransferRequest, direction upload).
    public func handleTransferRequest(direction: UInt32, token: UInt32, file: String,
                                      fileSize: UInt64?, from username: String) -> Data? {
        guard direction == TransferDirection.upload else { return nil }

        if let item = downloads.first(where: { $0.username == username && $0.virtualPath == file }),
           (item.status.isActive || item.status == .failed("Connection timeout")
            || item.status == .failed("Peer connection failed")), item.status != .transferring {
            let key = DownloadToken(username: username, token: token)
            if let existing = activeDownloads[key], existing !== item {
                onDiagnostic?("Rejected reused transfer token \(token) from \(username)")
                return PeerOut.transferResponse(token: token, allowed: false, reason: TransferRejectReason.queued)
            }
            guard activeDownloads.values.filter({ $0 !== item }).count < max(1, maxDownloadConnections) else {
                return PeerOut.transferResponse(token: token, allowed: false, reason: TransferRejectReason.queued)
            }
            for oldToken in activeDownloads.keys.filter({ activeDownloads[$0] === item }) {
                activeDownloads[oldToken] = nil
            }
            if let fileSize, fileSize > 0 {
                item.size = fileSize
            }
            item.status = .connecting
            item.queuePosition = 0
            item.queuePositionIsStale = false
            activeDownloads[key] = item
            onDiagnostic?("Accepted upload offer: peer=\(username), token=\(token), id=\(item.id), size=\(item.size)")
            startTimeout(for: item)
            notifyChanged()
            return PeerOut.transferResponse(token: token, allowed: true)
        }

        if let item = downloads.first(where: { $0.username == username && $0.virtualPath == file }),
           item.status == .finished {
            return PeerOut.transferResponse(token: token, allowed: false, reason: TransferRejectReason.complete)
        }

        return PeerOut.transferResponse(token: token, allowed: false, reason: TransferRejectReason.cancelled)
    }

    /// File connection opened by the uploader; `token` came in FileTransferInit.
    public func handleDownloadConnectionOpened(connectionID: UInt64, username: String, token: UInt32) {
        guard let item = activeDownloads[DownloadToken(username: username, token: token)],
              !downloadConnections.values.contains(where: { $0 === item }) else {
            onDiagnostic?("Rejected file socket \(connectionID): peer=\(username), unknown or duplicate transfer token=\(token)")
            gateway?.closeFileConnection(connectionID)
            return
        }
        downloadConnections[connectionID] = item

        let partialURL = partialFileURL(for: item)
        let existing: UInt64
        if let handle = try? FileHandle(forReadingFrom: partialURL) {
            existing = UInt64((try? handle.seekToEnd()) ?? 0)
            try? handle.close()
        } else {
            existing = 0
        }
        guard existing <= item.size else {
            deactivateDownload(item)
            item.status = .failed("Partial file exceeds expected size")
            gateway?.closeFileConnection(connectionID)
            notifyChanged()
            return
        }
        item.currentOffset = existing
        item.lastByteOffset = existing
        item.status = .transferring
        item.startedAt = Date()
        onDiagnostic?("Download socket \(connectionID) bound: peer=\(username), token=\(token), sending offset=\(existing), size=\(item.size)")
        gateway?.sendFileOffset(connectionID, existing)
        if existing == item.size {
            if existing == 0 { _ = createPartialFile(at: partialURL) }
            finishDownload(item, connectionID: connectionID)
        }
        notifyChanged()
    }

    public func handleDownloadData(connectionID: UInt64, data: Data) {
        guard let item = downloadConnections[connectionID] else { return }

        let partialURL = partialFileURL(for: item)
        guard let handle = (try? FileHandle(forWritingTo: partialURL))
            ?? createPartialFile(at: partialURL) else {
            deactivateDownload(item)
            item.status = .failed("Local file error")
            gateway?.closeFileConnection(connectionID)
            notifyChanged()
            return
        }
        defer { try? handle.close() }

        let remaining = item.size > item.currentOffset ? Int(min(UInt64(data.count), item.size - item.currentOffset)) : 0
        guard remaining > 0 else { return }
        let chunk = data.prefix(remaining)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk)
        } catch {
            deactivateDownload(item)
            item.status = .failed("Local file error")
            notifyChanged()
            return
        }
        item.currentOffset += UInt64(chunk.count)

        if let startedAt = item.startedAt, item.currentOffset > item.lastByteOffset {
            let elapsed = max(0.5, Date().timeIntervalSince(startedAt))
            item.speed = Double(item.currentOffset - item.lastByteOffset) / elapsed
        }

        if item.currentOffset >= item.size {
            finishDownload(item, connectionID: connectionID)
        }
        notifyChanged()
    }

    public func handleDownloadConnectionClosed(connectionID: UInt64, error: (any Error)?) {
        guard let item = downloadConnections[connectionID] else { return }
        downloadConnections[connectionID] = nil
        guard item.status == .transferring || item.status == .connecting else { return }

        if item.currentOffset >= item.size, item.size > 0 {
            finishDownload(item, connectionID: nil)
        } else {
            deactivateDownload(item)
            onDiagnostic?("Download socket closed: id=\(item.id), bytes=\(item.currentOffset)/\(item.size), error=\(error?.localizedDescription ?? "EOF")")
            item.status = .failed("Connection closed")
            notifyChanged()
            persist()
        }
    }

    public func handleUserWentOffline(_ username: String) {
        for item in downloads where item.username == username && item.status.isActive
            && item.status != .transferring {
            deactivateDownload(item)
            item.status = .userOffline
        }
        notifyChanged()
    }

    public func handleUserOnline(_ username: String) {
        for item in downloads where item.username == username && item.status == .userOffline {
            enqueueDownload(item, recovering: true)
        }
    }

    public func handlePeerConnectionFailed(_ username: String) {
        for item in downloads where item.username == username && item.status.isActive
            && item.status != .transferring {
            deactivateDownload(item)
            item.status = .failed("Peer connection failed")
        }
        for item in uploads where item.username == username && item.status == .connecting {
            abortActiveUpload(item, token: uploadToken(for: item))
            item.status = .failed("Peer connection failed")
        }
        checkUploadQueue()
        persist()
        notifyChanged()
    }

    private func finishDownload(_ item: DownloadItem, connectionID: UInt64?) {
        deactivateDownload(item)
        do {
            try movePartialToFinal(for: item)
            item.status = .finished
            onDiagnostic?("Download finished: peer=\(item.username), id=\(item.id), bytes=\(item.size)")
            item.currentOffset = item.size
        } catch {
            item.status = .failed("Could not save downloaded file")
        }
        if let connectionID {
            gateway?.closeFileConnection(connectionID)
            downloadConnections[connectionID] = nil
        }
        notifyChanged()
        persist()
    }

    private func deactivateDownload(_ item: DownloadItem) {
        if let token = activeDownloads.first(where: { $0.value === item })?.key {
            activeDownloads[token] = nil
        }
        if let connection = downloadConnections.first(where: { $0.value === item })?.key {
            downloadConnections[connection] = nil
            gateway?.closeFileConnection(connection)
        }
        timeoutTimers[item.id]?.invalidate()
        timeoutTimers[item.id] = nil
    }

    private func startTimeout(for item: TransferItem) {
        timeoutTimers[item.id]?.invalidate()
        let timer = Timer(fire: Date().addingTimeInterval(activationTimeout), interval: activationTimeout, repeats: false) { [weak self] _ in
            guard let self, item.status.isActive, item.status != .transferring else { return }
            if let download = item as? DownloadItem {
                self.onDiagnostic?("Download timed out: peer=\(download.username), id=\(download.id), stage=\(download.status.label)")
                self.deactivateDownload(download)
                download.status = .failed("Connection timeout")
                self.notifyChanged()
                self.persist()
            } else if let upload = item as? UploadItem {
                self.abortActiveUpload(upload, token: self.uploadToken(for: upload))
                upload.status = .failed("Connection timeout")
                self.gateway?.sendToPeer(upload.username, PeerOut.uploadFailed(upload.virtualPath))
                self.checkUploadQueue()
                self.persist()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        timeoutTimers[item.id] = timer
    }

    // MARK: - Uploads

    /// Peer asked us to queue a file (QueueUpload, peer code 43).
    public func handleQueueUpload(file: String, from username: String) -> Data? {
        if isBanned(username) {
            return PeerOut.uploadDenied(file: file, reason: TransferRejectReason.banned)
        }
        guard let shares, shares.isShared(virtualPath: file) else {
            return PeerOut.uploadDenied(file: file, reason: TransferRejectReason.fileNotShared)
        }
        if uploads.contains(where: { $0.username == username && $0.virtualPath == file && $0.status.isActive }) {
            return nil
        }

        let item = UploadItem(username: username, virtualPath: file,
                              size: shares.realURL(forVirtualPath: file)?.fileSize ?? 0)
        item.status = .queued
        uploads.append(item)
        checkUploadQueue()
        notifyChanged()
        persist()
        return nil
    }

    /// Legacy TransferRequest(direction 0): respond "Queued" and enqueue.
    public func handleLegacyDownloadRequest(token: UInt32, file: String, from username: String) -> Data {
        if isBanned(username) {
            return PeerOut.transferResponse(token: token, allowed: false, reason: TransferRejectReason.banned)
        }
        guard shares?.isShared(virtualPath: file) == true else {
            return PeerOut.transferResponse(token: token, allowed: false, reason: TransferRejectReason.fileNotShared)
        }
        _ = handleQueueUpload(file: file, from: username)
        return PeerOut.transferResponse(token: token, allowed: false, reason: TransferRejectReason.queued)
    }

    /// Peer asked for its position in our upload queue.
    public func handlePlaceInQueueRequest(file: String, from username: String) -> Data? {
        let waiting = uploads.filter { $0.status == .queued }
        guard let index = waiting.firstIndex(where: {
            $0.username == username && $0.virtualPath == file && $0.status == .queued
        }) else { return nil }
        return PeerOut.placeInQueueResponse(file: file, place: UInt32(index + 1))
    }

    /// Response to our TransferRequest(upload) offer.
    public func handleTransferResponse(token: UInt32, allowed: Bool, reason: String?, from username: String) {
        guard let item = activeUploads[token], item.username == username else { return }

        if allowed {
            item.status = .connecting
            gateway?.openUploadConnection(username: item.username, token: token)
            startTimeout(for: item)
            notifyChanged()
            return
        }

        abortActiveUpload(item, token: token)
        switch reason {
        case TransferRejectReason.queued:
            item.status = .remotelyQueued
        case TransferRejectReason.cancelled:
            item.status = .cancelled
        case TransferRejectReason.complete:
            item.status = .finished
        case let .some(other):
            item.status = .failed(other)
        case .none:
            item.status = .failed("Denied")
        }
        checkUploadQueue()
        notifyChanged()
        persist()
    }

    public func handleUploadConnectionOpened(connectionID: UInt64, username: String, token: UInt32) {
        guard let item = activeUploads[token], item.status.isActive, item.username == username else {
            gateway?.closeFileConnection(connectionID)
            return
        }
        guard let url = shares?.realURL(forVirtualPath: item.virtualPath),
              let handle = try? FileHandle(forReadingFrom: url) else {
            abortActiveUpload(item, token: token)
            item.status = .failed("File read error.")
            gateway?.closeFileConnection(connectionID)
            checkUploadQueue()
            return
        }
        uploadConnections[connectionID] = (item, handle)
        item.status = .connecting
        startTimeout(for: item)
        notifyChanged()
    }

    public func handleUploadOffset(connectionID: UInt64, offset: UInt64) {
        guard let entry = uploadConnections[connectionID] else { return }
        let item = entry.upload
        guard item.status == .connecting, offset <= item.size else {
            abortUploadWithError(connectionID: connectionID, item: item)
            return
        }
        do {
            try entry.handle.seek(toOffset: offset)
        } catch {
            abortUploadWithError(connectionID: connectionID, item: item)
            return
        }
        timeoutTimers[item.id]?.invalidate()
        timeoutTimers[item.id] = nil
        item.currentOffset = offset
        item.lastByteOffset = offset
        item.status = .transferring
        item.startedAt = Date()
        sendNextUploadChunk(connectionID: connectionID)
        notifyChanged()
    }

    private func sendNextUploadChunk(connectionID: UInt64) {
        guard let entry = uploadConnections[connectionID] else { return }
        let item = entry.upload
        let remaining = item.size > item.currentOffset ? item.size - item.currentOffset : 0
        guard remaining > 0 else {
            finishUpload(connectionID: connectionID, item: item)
            return
        }

        let length = Int(min(UInt64(TransferManager.chunkSize), remaining))
        guard let chunk = try? entry.handle.read(upToCount: length), !chunk.isEmpty else {
            abortUploadWithError(connectionID: connectionID, item: item)
            return
        }
        guard let gateway else {
            abortUploadWithError(connectionID: connectionID, item: item)
            return
        }
        gateway.sendFileData(connectionID, chunk) { [weak self] error in
            guard let self, self.uploadConnections[connectionID]?.upload === item else { return }
            if error != nil {
                self.abortUploadWithError(connectionID: connectionID, item: item)
                self.notifyChanged()
                return
            }
            item.currentOffset += UInt64(chunk.count)
            item.speed = self.uploadSpeed(item: item, bytes: item.currentOffset - item.lastByteOffset)
            self.notifyChanged()
            DispatchQueue.main.async { [weak self] in
                self?.sendNextUploadChunk(connectionID: connectionID)
            }
        }
        notifyChanged()
    }

    private func uploadSpeed(item: UploadItem, bytes: UInt64) -> Double {
        guard let startedAt = item.startedAt else { return 0 }
        let elapsed = max(0.5, Date().timeIntervalSince(startedAt))
        return Double(bytes) / elapsed
    }

    public func handleUploadConnectionClosed(connectionID: UInt64, error: (any Error)?) {
        guard let entry = uploadConnections[connectionID] else { return }
        uploadConnections[connectionID] = nil
        try? entry.handle.close()
        let item = entry.upload

        if item.currentOffset >= item.size, item.size > 0 {
            completeUpload(item)
        } else {
            abortActiveUpload(item, token: uploadToken(for: item))
            item.status = .failed("Connection closed")
            // Let the downloader know so it can re-queue.
            gateway?.sendToPeer(item.username, PeerOut.uploadFailed(item.virtualPath))
            checkUploadQueue()
        }
        notifyChanged()
        persist()
    }

    private func uploadToken(for item: UploadItem) -> UInt32? {
        activeUploads.first(where: { $0.value === item })?.key
    }

    private func finishUpload(connectionID: UInt64, item: UploadItem) {
        if let entry = uploadConnections.removeValue(forKey: connectionID) {
            try? entry.handle.close()
        }
        gateway?.closeFileConnection(connectionID)
        completeUpload(item)
        checkUploadQueue()
        persist()
    }

    private func completeUpload(_ item: UploadItem) {
        if let token = activeUploads.first(where: { $0.value === item })?.key {
            activeUploads[token] = nil
        }
        item.status = .finished
        item.currentOffset = item.size
        item.speed = 0
        if let startedAt = item.startedAt {
            let elapsed = max(1, Date().timeIntervalSince(startedAt))
            let avg = UInt32(Double(item.size) / elapsed)
            onUploadFinishedSpeed?(avg)
        }
    }

    private func abortUploadWithError(connectionID: UInt64, item: UploadItem) {
        if let entry = uploadConnections.removeValue(forKey: connectionID) {
            try? entry.handle.close()
        }
        gateway?.closeFileConnection(connectionID)
        abortActiveUpload(item, token: uploadToken(for: item))
        item.status = .failed("File read error.")
        checkUploadQueue()
    }

    private func abortActiveUpload(_ item: UploadItem, token: UInt32?) {
        if let token {
            activeUploads[token] = nil
        }
        timeoutTimers[item.id]?.invalidate()
        timeoutTimers[item.id] = nil
        for (id, entry) in uploadConnections where entry.upload === item {
            uploadConnections[id] = nil
            try? entry.handle.close()
            gateway?.closeFileConnection(id)
        }
    }

    private func checkUploadQueue() {
        var active = activeUploads.count
        while active < max(1, uploadSlots) {
            guard let candidate = uploads.first(where: { $0.status == .queued }) else { break }
            guard shares?.isShared(virtualPath: candidate.virtualPath) == true else {
                candidate.status = .failed(TransferRejectReason.fileNotShared)
                continue
            }
            candidate.size = shares?.realURL(forVirtualPath: candidate.virtualPath)?.fileSize ?? candidate.size

            let token = tokens.next()
            activeUploads[token] = candidate
            candidate.status = .connecting
            candidate.queuePosition = 0
            gateway?.sendToPeer(candidate.username,
                                PeerOut.transferRequest(direction: TransferDirection.upload,
                                                        token: token,
                                                        file: candidate.virtualPath,
                                                        fileSize: candidate.size))
            startTimeout(for: candidate)
            active += 1
        }
        notifyChanged()
    }

    func queueMaintenanceTick() {
        for item in downloads where item.status == .queued || item.status == .remotelyQueued {
            if timeoutTimers[item.id] == nil { startTimeout(for: item) }
            gateway?.sendToPeer(item.username, PeerOut.placeInQueueRequest(item.virtualPath))
        }
        checkUploadQueue()
    }

    // MARK: - File paths

    public func finalFileURL(for item: DownloadItem) -> URL {
        let safeName = item.fileName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        var url = downloadDirectory.appendingPathComponent(safeName)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloadDirectory.appendingPathComponent("\(safeName) (\(counter))")
            counter += 1
        }
        return url
    }

    private func partialFileURL(for item: DownloadItem) -> URL {
        return downloadDirectory
            .appendingPathComponent("Partials")
            .appendingPathComponent(item.id.uuidString + ".slskpart")
    }

    private func createPartialFile(at url: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: url)
    }

    private func movePartialToFinal(for item: DownloadItem) throws {
        let partial = partialFileURL(for: item)
        let final = finalFileURL(for: item)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: partial, to: final)
        item.localFilePath = final.path
    }

    private func removePartialFile(for item: DownloadItem) {
        try? FileManager.default.removeItem(at: partialFileURL(for: item))
    }

    // MARK: - Persistence

    private func loadPersisted() {
        guard let storage else { return }
        if let savedDownloads = storage.load([DownloadItem].self, as: "downloads") {
            downloads = savedDownloads.filter { $0.status != .cancelled && $0.status != .filtered }
            for item in downloads where item.status.isActive { item.status = .paused }
        }
        if let savedUploads = storage.load([UploadItem].self, as: "uploads") {
            uploads = savedUploads.filter { $0.status == .finished }
        }
    }

    public func persist() {
        guard let storage else { return }
        let keepDownloads = downloads.filter { $0.status != .cancelled && $0.status != .filtered }
        let keepUploads = uploads.filter { $0.status == .finished }
        let unfinished = keepDownloads.filter { $0.status != .finished }
        let history = keepDownloads.filter { $0.status == .finished }.suffix(500)
        storage.save(unfinished + history, as: "downloads")
        storage.save(Array(keepUploads.prefix(500)), as: "uploads")
    }

    private func notifyChanged() {
        onChanged?()
    }

    public func serverWentOffline() {
        for item in downloads where item.status.isActive {
            deactivateDownload(item)
            item.queuePositionIsStale = item.queuePosition > 0
            item.status = .userOffline
        }
        for (connectionID, entry) in uploadConnections {
            try? entry.handle.close()
            gateway?.closeFileConnection(connectionID)
            _ = connectionID
        }
        uploadConnections.removeAll()
        for item in uploads where item.status.isActive {
            item.status = .userOffline
        }
        activeUploads.removeAll()
        activeDownloads.removeAll()
        for timer in timeoutTimers.values { timer.invalidate() }
        timeoutTimers.removeAll()
        notifyChanged()
    }

    public var activeUploadCount: Int { activeUploads.count }
    public var queuedUploadCount: Int { uploads.filter { $0.status == .queued }.count }
}

extension URL {
    var fileSize: UInt64 {
        (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init) ?? 0
    }
}

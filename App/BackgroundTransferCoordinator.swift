import BackgroundTasks
import Combine
import UIKit

/// Asks iOS for extra execution time while downloads are in flight.
///
/// - All supported iOS versions: a short `beginBackgroundTask` grace period
///   after backgrounding, so sockets stay up and state is saved before suspension.
/// - iOS 26+: a `BGContinuedProcessingTask`, submitted while the app is in the
///   foreground, which lets the system keep the process running and shows
///   progress the user can cancel. The system may still expire it.
///
/// Neither is unlimited background downloading; expiry just means the app is
/// suspended and automatic resume takes over when it runs again.
@MainActor
final class BackgroundTransferCoordinator {
    static let continuedTaskIdentifier = "app.slsk.ios.downloads.continued"

    private let client: SoulseekClient
    private var observer: AnyCancellable?
    private var isForeground = true
    private var graceTask: UIBackgroundTaskIdentifier = .invalid
    private var continuedTask: AnyObject?
    private var continuedRequested = false
    private var lastProgressUpdate = Date.distantPast

    init(client: SoulseekClient) {
        self.client = client
        if #available(iOS 26.0, *) { registerContinuedTask() }
        observer = client.$transferRevision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.transfersChanged() }
    }

    func appDidBecomeActive() {
        isForeground = true
        endGraceTask()
        transfersChanged()
    }

    func appDidEnterBackground() {
        isForeground = false
        guard !client.downloadActivity.isEmpty, graceTask == .invalid else { return }
        graceTask = UIApplication.shared.beginBackgroundTask(withName: "slsk.downloads") { [weak self] in
            self?.client.recordBackgroundExecution("grace period expired")
            self?.client.saveAll()
            self?.endGraceTask()
        }
        client.recordBackgroundExecution("grace period started")
    }

    private func transfersChanged() {
        let activity = client.downloadActivity
        if activity.isEmpty {
            endGraceTask()
        }
        if #available(iOS 26.0, *) { updateContinuedTask(activity) }
    }

    private func endGraceTask() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }

    // MARK: iOS 26 continued processing

    @available(iOS 26.0, *)
    private func registerContinuedTask() {
        // Must happen before launch finishes; AppState is created at app start.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.continuedTaskIdentifier, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            Task { @MainActor in self?.begin(task) }
        }
    }

    @available(iOS 26.0, *)
    private func begin(_ task: BGContinuedProcessingTask) {
        continuedTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.client.recordBackgroundExecution("continued task expired")
                self.client.saveAll()
                self.finishContinuedTask(success: false)
            }
        }
        client.recordBackgroundExecution("continued task started")
        updateContinuedTask(client.downloadActivity, force: true)
    }

    @available(iOS 26.0, *)
    private func updateContinuedTask(_ activity: DownloadActivity, force: Bool = false) {
        if let task = continuedTask as? BGContinuedProcessingTask {
            if activity.isEmpty {
                finishContinuedTask(success: true)
                return
            }
            let now = Date()
            guard force || now.timeIntervalSince(lastProgressUpdate) >= 1 else { return }
            lastProgressUpdate = now
            task.progress.totalUnitCount = Int64(clamping: activity.totalBytes)
            task.progress.completedUnitCount = Int64(clamping: activity.completedBytes)
            let noun = activity.count == 1 ? "download" : "downloads"
            let percent = activity.totalBytes == 0 ? 0 : Int(Double(activity.completedBytes) / Double(activity.totalBytes) * 100)
            task.updateTitle("Slsk", subtitle: "\(activity.count) \(noun) · \(percent)%")
        } else if isForeground, !continuedRequested, !activity.isEmpty {
            // The request is tied to the foregrounded app, so only submit then.
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.continuedTaskIdentifier, title: "Slsk",
                subtitle: "Downloading files")
            do {
                try BGTaskScheduler.shared.submit(request)
                continuedRequested = true
            } catch {
                client.recordBackgroundExecution("continued task unavailable (\((error as NSError).code))")
            }
        }
    }

    @available(iOS 26.0, *)
    private func finishContinuedTask(success: Bool) {
        (continuedTask as? BGContinuedProcessingTask)?.setTaskCompleted(success: success)
        continuedTask = nil
        continuedRequested = false
    }
}

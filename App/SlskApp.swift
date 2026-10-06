import SwiftUI
import UIKit

@main
struct SlskApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.client)
                .modifier(SlskTheme())
                .onAppear {
                    appState.recordScenePhase(scenePhase)
                }
                .onChange(of: scenePhase) { phase in
                    appState.recordScenePhase(phase)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    appState.client.recordAppMemoryWarning()
                }
        }
    }
}

/// App-level state: owns the client, first-run login routing and persistence.
@MainActor
final class AppState: ObservableObject {
    let client: SoulseekClient
    @Published var needsLogin: Bool

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let storage = Storage(baseURL: documents.appendingPathComponent("SlskData", isDirectory: true))
        let client = SoulseekClient(factory: TCPTransportFactory(), storage: storage,
                                    config: ClientConfiguration(), passwordStore: PasswordKeychain())
        self.client = client
        client.start()
        needsLogin = client.config.username.isEmpty || client.config.password.isEmpty
        let sharedDirectories = ShareBookmarks.shared.resolveAll()
        if !sharedDirectories.isEmpty { client.setSharedDirectories(sharedDirectories) }
    }

    func loggedIn() {
        needsLogin = false
    }

    func recordScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active: client.recordAppLifecycle(.active)
        case .inactive: client.recordAppLifecycle(.inactive)
        case .background:
            client.recordAppLifecycle(.background)
            client.saveAll()
        @unknown default: break
        }
    }
}

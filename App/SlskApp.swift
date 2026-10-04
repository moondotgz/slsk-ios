import SwiftUI

@main
struct SlskApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.client)
                .tint(.orange)
                .onChange(of: scenePhase) { phase in
                    if phase == .background {
                        appState.client.saveAll()
                    }
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
                                    config: ClientConfiguration())
        self.client = client
        needsLogin = client.config.username.isEmpty
        client.start()
    }

    func loggedIn() {
        needsLogin = false
    }
}

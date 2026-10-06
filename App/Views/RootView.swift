import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: SoulseekClient

    var body: some View {
        Group {
            if appState.needsLogin {
                NavigationStack {
                    LoginView()
                }
            } else {
                TabView {
                    SearchView()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    TransfersView()
                        .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
                    ChatView()
                        .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    UsersView()
                        .tabItem { Label("Users", systemImage: "person.2") }
                    SharesView()
                        .tabItem { Label("Shares", systemImage: "folder.badge.plus") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        .onAppear {
            if !appState.needsLogin, client.connectionState == .disconnected,
               !client.config.username.isEmpty {
                client.connect()
            }
        }
        .onReceive(client.$connectionState) { state in
            if state == .loggedIn { appState.loggedIn() }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: SoulseekClient
    @State private var username = ""
    @State private var password = ""
    @State private var server = ""
    @State private var port = ""

    var body: some View {
        Form {
            Section {
                Text("Slsk")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .foregroundStyle(.tint)
            }

            Section("Soulseek account") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
            }

            Section("Server") {
                TextField("Host", text: $server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            }

            Section {
                Button {
                    client.config.serverHost = server
                    client.config.serverPort = UInt16(port) ?? 2242
                    client.login(username: username, password: password)
                } label: {
                    HStack {
                        Spacer()
                        if client.connectionState == .connecting || client.connectionState == .loggingIn {
                            ProgressView()
                        } else {
                            Text("Log in")
                                .bold()
                        }
                        Spacer()
                    }
                }
                .slskGlassButton(prominent: true)
                .disabled(username.isEmpty || password.isEmpty
                          || client.connectionState == .connecting
                          || client.connectionState == .loggingIn)
            }

            if case let .failed(message) = client.connectionState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            if let message = client.credentialStorageError {
                Section("Password storage") {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .slskScreen()
        .navigationTitle("Login")
        .onAppear {
            username = client.config.username
            password = client.config.password
            server = client.config.serverHost
            port = String(client.config.serverPort)
        }
    }
}

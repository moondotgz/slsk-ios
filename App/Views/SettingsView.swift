import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var newPassword = ""
    @State private var newLike = ""
    @State private var newHate = ""
    @State private var newWish = ""
    @State private var uploadSlots = "2"
    @State private var listenPort = "2234"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Username", value: client.config.username)
                    LabeledContent("Status") {
                        if case .loggedIn = client.connectionState {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if case let .failed(reason) = client.connectionState {
                            Label(reason, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        } else {
                            Text(client.connectionState == .disconnected ? "Disconnected" : "Connecting…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if case .loggedIn = client.connectionState {
                        Button("Disconnect") {
                            client.disconnect()
                        }
                        .foregroundStyle(.red)
                    } else if !client.config.username.isEmpty {
                        Button("Connect") {
                            client.connect()
                        }
                    }
                    if case .loggedIn = client.connectionState {
                        Toggle("Away", isOn: Binding(
                            get: { client.isAway },
                            set: { client.setAway($0) }
                        ))
                    }
                } header: {
                    Text("Connection")
                }

                Section {
                    LabeledContent("Server", value: "\(client.config.serverHost):\(client.config.serverPort)")
                    LabeledContent("Listen port", value: "\(client.listenPort)")
                    LabeledContent("Privileges remaining") {
                        Text(privilegesText)
                    }
                } header: {
                    Text("Network")
                }

                Section {
                    TextField("Upload slots", text: $uploadSlots)
                        .keyboardType(.numberPad)
                        .onSubmit(saveSlots)
                    TextField("Download folder name", text: Binding(
                        get: { client.config.downloadFolderName },
                        set: { client.config.downloadFolderName = $0; client.saveConfig() }
                    ))
                    LabeledContent("Download location") {
                        Text("Files/\(client.config.downloadFolderName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Transfers")
                } footer: {
                    Text("Downloads appear in the app folder, visible in the Files app.")
                }

                Section {
                    ForEach(client.config.likes, id: \.self) { like in
                        HStack {
                            Image(systemName: "hand.thumbsup.fill")
                                .foregroundStyle(.green)
                            Text(like)
                            Spacer()
                            Button(role: .destructive) {
                                client.removeLike(like)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Add something you like", text: $newLike)
                            .onSubmit(addLike)
                        Button("Add") { addLike() }
                            .disabled(newLike.isEmpty)
                    }
                } header: {
                    Text("Likes (recommendations)")
                }

                Section {
                    ForEach(client.config.hates, id: \.self) { hate in
                        HStack {
                            Image(systemName: "hand.thumbsdown.fill")
                                .foregroundStyle(.red)
                            Text(hate)
                            Spacer()
                            Button(role: .destructive) {
                                client.removeHate(hate)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Add something you dislike", text: $newHate)
                            .onSubmit(addHate)
                        Button("Add") { addHate() }
                            .disabled(newHate.isEmpty)
                    }
                } header: {
                    Text("Dislikes")
                }

                Section {
                    ForEach(client.config.wishlist, id: \.self) { wish in
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                            Text(wish)
                            Spacer()
                            Button(role: .destructive) {
                                var items = client.config.wishlist
                                items.removeAll { $0 == wish }
                                client.setWishlist(items)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Add wishlist search", text: $newWish)
                            .onSubmit(addWish)
                        Button("Add") { addWish() }
                            .disabled(newWish.isEmpty)
                    }
                } header: {
                    Text("Wishlist")
                } footer: {
                    Text("Re-searched automatically at the server's wishlist interval.")
                }

                Section {
                    if client.config.bannedUsers.isEmpty {
                        Text("No banned users")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(client.config.bannedUsers, id: \.self) { user in
                        HStack {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(.red)
                            Text(user)
                            Spacer()
                            Button("Unban") { client.unbanUser(user) }
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Banned users")
                }

                Section {
                    if client.config.ignoredUsers.isEmpty {
                        Text("No ignored users")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(client.config.ignoredUsers, id: \.self) { user in
                        HStack {
                            Image(systemName: "eye.slash")
                            Text(user)
                            Spacer()
                            Button("Unignore") { client.unignoreUser(user) }
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Ignored users")
                }

                Section {
                    SecureField("New password", text: $newPassword)
                    Button("Change password") {
                        client.changePassword(newPassword)
                        newPassword = ""
                    }
                    .disabled(newPassword.isEmpty)
                } header: {
                    Text("Account")
                }

                Section {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Protocol") {
                        Text("Soulseek (Nicotine+ compatible)")
                            .font(.footnote)
                    }
                    Text("Use responsibly and in accordance with the Soulseek server rules. Downloads land in this app's Documents folder, shared folders are served from Files.app folders you pick.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .slskScreen()
            .navigationTitle("Settings")
            .onAppear {
                uploadSlots = String(client.transfers.uploadSlots)
                listenPort = String(client.config.listenPort)
            }
        }
    }

    private var privilegesText: String {
        guard client.privilegesSeconds > 0 else { return "None" }
        let days = client.privilegesSeconds / 86400
        let hours = (client.privilegesSeconds % 86400) / 3600
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
    }

    private func saveSlots() {
        client.transfers.uploadSlots = max(1, Int(uploadSlots) ?? 2)
        client.config.uploadSlots = client.transfers.uploadSlots
        client.saveConfig()
    }

    private func addLike() {
        let item = newLike.trimmingCharacters(in: .whitespaces)
        client.addLike(item)
        newLike = ""
    }

    private func addHate() {
        let item = newHate.trimmingCharacters(in: .whitespaces)
        client.addHate(item)
        newHate = ""
    }

    private func addWish() {
        let item = newWish.trimmingCharacters(in: .whitespaces)
        var items = client.config.wishlist
        guard !item.isEmpty, !items.contains(item) else { return }
        items.append(item)
        client.setWishlist(items)
        newWish = ""
    }
}

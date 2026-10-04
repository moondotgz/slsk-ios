import SwiftUI

struct UsersView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var newBuddy = ""
    @State private var selectedUser: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Add buddy") {
                    HStack {
                        TextField("Username", text: $newBuddy)
                            .textInputAutocapitalization(.never)
                        Button("Add") {
                            let name = newBuddy.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            client.addBuddy(name)
                            newBuddy = ""
                        }
                        .disabled(newBuddy.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("Buddies") {
                    if client.config.buddies.isEmpty {
                        Text("No buddies yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(client.config.buddies, id: \.self) { username in
                        Button {
                            selectedUser = username
                        } label: {
                            BuddyRow(username: username)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !client.distributed.children.isEmpty {
                    Section("Distributed children") {
                        ForEach(Array(client.distributed.children).sorted(), id: \.self) { child in
                            Label(child, systemImage: "arrow.triangle.branch")
                        }
                    }
                }

                Section {
                    LabeledContent("Branch root", value: client.distributed.branchRoot ?? "—")
                    LabeledContent("Branch level", value: "\(client.distributed.branchLevel)")
                    LabeledContent("Parent", value: client.distributed.parentUsername ?? "none (branch root)")
                    LabeledContent("Listen port", value: "\(client.listenPort)")
                } header: {
                    Text("Distributed network")
                }
            }
            .navigationTitle("Users")
            .sheet(item: selectedUserBinding) { username in
                UserSheet(username: username)
            }
        }
    }

    private var selectedUserBinding: Binding<String?> {
        Binding(get: { selectedUser }, set: { selectedUser = $0 })
    }
}

struct BuddyRow: View {
    @EnvironmentObject private var client: SoulseekClient
    let username: String

    var body: some View {
        HStack {
            StatusDot(status: client.users[username]?.status ?? 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(username)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    if let info = client.users[username] {
                        if info.privileged {
                            Image(systemName: "crown.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text("\(info.stats.sharedFiles) files")
                        Text(Format.speed(Double(info.stats.avgSpeed)))
                    } else {
                        Text("Unknown")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

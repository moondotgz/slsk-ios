import SwiftUI

// MARK: - Formatting helpers

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: UInt64) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func bitrate(_ info: RemoteFileInfo) -> String? {
        if let bitrate = info.bitrate {
            var text = "\(bitrate) kbps"
            if info.vbr == 1 { text += " vbr" }
            return text
        }
        if let sampleRate = info.sampleRate, let bitDepth = info.bitDepth {
            return "\(sampleRate / 1000) kHz / \(bitDepth) bit"
        }
        return nil
    }
}

// MARK: - Status dot

struct StatusDot: View {
    let status: UInt32

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }

    private var color: Color {
        switch status {
        case UserStatusValue.online: .green
        case UserStatusValue.away: .orange
        default: .gray
        }
    }
}

// MARK: - User sheet (detail + actions)

struct UserSheet: View {
    @EnvironmentObject private var client: SoulseekClient
    @Environment(\.dismiss) private var dismiss
    let username: String
    @State private var message = ""
    @State private var peerInfo: PeerUserInfo?
    @State private var showBrowse = false

    var body: some View {
        NavigationStack {
            List {
                Section(username) {
                    if let info = client.users[username] {
                        HStack {
                            StatusDot(status: info.status)
                            Text(statusLabel(info.status))
                        }
                        if info.privileged {
                            Label("Privileged", systemImage: "crown.fill")
                                .foregroundStyle(.tint)
                        }
                        if let country = info.country, !country.isEmpty {
                            Label("Country: \(country)", systemImage: "globe")
                        }
                        Label("\(Format.speed(Double(info.stats.avgSpeed))) upload speed", systemImage: "speedometer")
                        Label("\(info.stats.sharedFiles) files in \(info.stats.sharedFolders) folders",
                              systemImage: "folder")
                    } else {
                        Text("Unknown user")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Message") {
                    TextField("Private message", text: $message, axis: .vertical)
                    Button("Send") {
                        client.sendMessage(to: username, message)
                        message = ""
                    }
                    .disabled(message.isEmpty)
                }

                Section("Actions") {
                    Button {
                        showBrowse = true
                    } label: {
                        Label("Browse shares", systemImage: "folder")
                    }
                    Button {
                        client.requestUserInfo(username) { user, info in
                            if user == username { peerInfo = info }
                        }
                    } label: {
                        Label("Request user info", systemImage: "info.circle")
                    }
                    Button {
                        client.requestUserInterests(username)
                    } label: {
                        Label("Request interests", systemImage: "heart.text.square")
                    }
                    if let info = peerInfo {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.description.isEmpty ? "No description" : info.description)
                                .font(.footnote)
                        }
                    }
                    if let interests = client.userInterests[username] {
                        VStack(alignment: .leading, spacing: 4) {
                            if !interests.likes.isEmpty {
                                Text("Likes: " + interests.likes.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !interests.hates.isEmpty {
                                Text("Dislikes: " + interests.hates.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Moderation") {
                    if client.config.buddies.contains(username) {
                        Button(role: .destructive) {
                            client.removeBuddy(username)
                        } label: {
                            Label("Remove from buddies", systemImage: "person.badge.minus")
                        }
                    } else {
                        Button {
                            client.addBuddy(username)
                        } label: {
                            Label("Add to buddies", systemImage: "person.badge.plus")
                        }
                    }
                    Button(role: .destructive) {
                        client.banUser(username)
                    } label: {
                        Label("Ban user", systemImage: "hand.raised")
                    }
                    Button(role: .destructive) {
                        client.ignoreUser(username)
                    } label: {
                        Label("Ignore user", systemImage: "eye.slash")
                    }
                }
            }
            .slskScreen()
            .navigationTitle("User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showBrowse) {
                BrowseSheet(username: username)
            }
        }
    }

    private func statusLabel(_ status: UInt32) -> String {
        switch status {
        case UserStatusValue.online: "Online"
        case UserStatusValue.away: "Away"
        default: "Offline"
        }
    }
}

// MARK: - Browse sheet

struct BrowseSheet: View {
    @EnvironmentObject private var client: SoulseekClient
    @Environment(\.dismiss) private var dismiss
    let username: String
    @State private var selectedFolder: String?

    var body: some View {
        NavigationStack {
            Group {
                if let session = client.browseSession(for: username), !session.folders.isEmpty {
                    List {
                        ForEach(session.folderNames, id: \.self) { folder in
                            FolderRow(username: username, folder: folder,
                                      files: session.folders[folder] ?? [])
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.largeTitle)
                        Text("Browsing \(username)")
                            .font(.headline)
                        Text("Waiting for the share list…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .slskScreen()
            .navigationTitle("Browse \(username)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if client.browseSession(for: username) == nil {
                client.browseUser(username)
            }
        }
    }
}

struct FolderRow: View {
    @EnvironmentObject private var client: SoulseekClient
    let username: String
    let folder: String
    let files: [RemoteFileInfo]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .foregroundStyle(.tint)
                    Text(folderName)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Text("\(files.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Button {
                    client.downloadFolder(folder, files: files, from: username)
                } label: {
                    Label("Download all (\(Format.bytes(files.reduce(0) { $0 + $1.size })))",
                          systemImage: "arrow.down.circle.fill")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)

                ForEach(files) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.fileName)
                                .font(.caption)
                            HStack(spacing: 8) {
                                Text(Format.bytes(file.size))
                                if let bitrate = Format.bitrate(file) { Text(bitrate) }
                                if let duration = file.durationSeconds { Text(Format.duration(UInt64(duration))) }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            client.download(file: file, from: username)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var folderName: String {
        folder.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? folder
    }
}

// MARK: - Transfer row

struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.fileName)
                .font(.subheadline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(item.username)
                    .foregroundStyle(.secondary)
                if item.status == .transferring {
                    Text("\(Format.bytes(item.currentOffset)) / \(Format.bytes(item.size))")
                    if item.speed > 0 {
                        Text(Format.speed(item.speed))
                    }
                } else if item.status == .finished {
                    Text(Format.bytes(item.size))
                } else if item.queuePosition > 0 {
                    Text("Queue #\(item.queuePosition)")
                } else {
                    Text(item.status.label)
                        .foregroundStyle(item.status == .finished ? .green : .secondary)
                }
            }
            .font(.caption)

            if item.status == .transferring, item.size > 0 {
                ProgressView(value: Double(item.currentOffset), total: Double(item.size))
            }
        }
        .padding(.vertical, 2)
    }
}

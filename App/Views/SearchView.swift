import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var query = ""
    @State private var freeSlotOnly = false
    @State private var minBitrate = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(client.search.activeSessions, id: \.token) { session in
                    Section {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.query.rawText)
                                    .font(.subheadline.weight(.medium))
                                Text("\(session.hits.count) results from \(sessionFolderCount(session)) folders")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                client.removeSearchSession(token: session.token)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        let folders = session.folders().prefix(20)
                        ForEach(Array(folders), id: \.self) { folder in
                            SearchFolderSection(username: nil, folder: folder,
                                                hits: session.hits(inFolder: folder))
                        }
                        if session.folders().count > 20 {
                            Text("More folders not shown…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if client.search.activeSessions.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No active searches")
                            Text("Searches also support -excluded and \"quoted phrases\".")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .slskScreen()
            .safeAreaInset(edge: .top, spacing: 0) {
                searchControls
                    .padding(16)
                    .slskGlassSurface(cornerRadius: 28)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .navigationTitle("Search")
            .onAppear {
                freeSlotOnly = client.search.filter.freeSlotOnly
                let minimum = client.search.filter.minimumBitrate
                minBitrate = minimum == 0 ? "" : String(minimum)
            }
        }
    }

    private var searchControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                TextField("Search files…", text: $query)
                    .onSubmit(submitSearch)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 8)
                Button(action: submitSearch) {
                    Image(systemName: "magnifyingglass")
                        .frame(minWidth: 24, minHeight: 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Search files")
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            DisclosureGroup("Filters") {
                Toggle("Free upload slot only", isOn: $freeSlotOnly)
                    .font(.subheadline)
                    .onChange(of: freeSlotOnly) { _ in
                        client.search.filter.freeSlotOnly = freeSlotOnly
                    }
                    .padding(.vertical, 8)
                HStack {
                    TextField("Min bitrate (kbps)", text: $minBitrate)
                        .keyboardType(.numberPad)
                    Button("Apply") {
                        client.search.filter.minimumBitrate = UInt32(minBitrate) ?? 0
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }

    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        client.startSearch(text)
        query = ""
    }

    private func sessionFolderCount(_ session: SearchSession) -> Int {
        session.folders().count
    }
}

/// Renders the hits of one folder, grouped under a collapsible header with a
/// "download folder" action. Also used by user-search result views.
struct SearchFolderSection: View {
    @EnvironmentObject private var client: SoulseekClient
    let username: String?
    let folder: String
    let hits: [SearchHit]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lastFolderComponent)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let user = hits.first?.username {
                            Text(user)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if hits.contains(where: { $0.freeUploadSlot }) {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Text("\(hits.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(hits) { hit in
                    HitRow(hit: hit)
                }
            }
        }
    }

    private var lastFolderComponent: String {
        folder.split(separator: "\\", omittingEmptySubsequences: false).suffix(2)
            .joined(separator: "\\")
    }
}

struct HitRow: View {
    @Environment(\.slskAccent) private var accent
    @Environment(\.slskRowDensity) private var density
    @EnvironmentObject private var client: SoulseekClient
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.file.fileName)
                    .font(.caption.weight(.medium))
                HStack(spacing: 8) {
                    Text(Format.bytes(hit.file.size))
                    if let bitrate = Format.bitrate(hit.file) { Text(bitrate) }
                    if let duration = hit.file.durationSeconds {
                        Text(Format.duration(UInt64(duration)))
                    }
                    if hit.freeUploadSlot {
                        Text("slot free")
                            .foregroundStyle(.green)
                    } else if hit.queueLength > 0 {
                        Text("queue \(hit.queueLength)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    client.download(file: hit.file, from: hit.username)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                Button {
                    client.requestFolderContents(username: hit.username, folder: hit.file.folder) { folders in
                        let files = folders.values.flatMap { $0 }
                        client.downloadFolder(hit.file.folder, files: files, from: hit.username)
                    }
                } label: {
                    Label("Download folder (recursive)", systemImage: "arrow.down.circle.fill")
                }
                Button {
                    client.addBuddy(hit.username)
                } label: {
                    Label("Add buddy", systemImage: "person.badge.plus")
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(hit.freeUploadSlot ? Color.green : accent)
            }
        }
        .padding(.vertical, density.padding)
    }
}

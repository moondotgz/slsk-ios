import SwiftUI
import UniformTypeIdentifiers

/// Persists security-scoped bookmarks for shared folders so access survives
/// relaunches (iOS sandbox requirement).
final class ShareBookmarks {
    static let shared = ShareBookmarks()
    private var bookmarks: [String: Data] = [:]
    private var fileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("SlskData/share-bookmarks.plist")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            bookmarks = decoded
        }
    }

    func save(url: URL) {
        guard let data = try? url.bookmarkData() else { return }
        bookmarks[url.lastPathComponent] = data
        persist()
    }

    func remove(named name: String) {
        bookmarks.removeValue(forKey: name)
        persist()
    }

    /// Resolve all stored bookmarks and start security-scoped access.
    func resolveAll() -> [URL] {
        var urls: [URL] = []
        for (_, data) in bookmarks {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                url.startAccessingSecurityScopedResource()
                urls.append(url)
            }
        }
        return urls
    }

    private func persist() {
        if let data = try? PropertyListEncoder().encode(bookmarks) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

struct SharesView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var showImporter = false
    @State private var description = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        LabeledContent("Files", value: "\(client.shares.sharedFileCount)")
                        LabeledContent("Folders", value: "\(client.shares.sharedFolderCount)")
                    }
                    .font(.footnote)
                    if client.shares.isScanning {
                        HStack {
                            ProgressView()
                            Text("Scanning shares…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let lastScan = client.shares.lastScanDate {
                        Text("Last scanned \(lastScan.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        client.rescanShares()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Index")
                }

                Section {
                    if client.shares.sharedDirectories.isEmpty {
                        Text("No folders shared")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(client.shares.sharedDirectories, id: \.absoluteString) { url in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            ShareBookmarks.shared.remove(named: client.shares.sharedDirectories[index].lastPathComponent)
                        }
                        var remaining = client.shares.sharedDirectories
                        remaining.remove(atOffsets: indexSet)
                        client.setSharedDirectories(remaining)
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Add folder…", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Shared folders")
                } footer: {
                    Text("Pick folders from the Files app; they are indexed and served to other Soulseek users.")
                }

                Section {
                    TextField("Describe yourself / your shares", text: $description, axis: .vertical)
                        .onSubmit(saveDescription)
                    Button("Save description") {
                        saveDescription()
                    }
                } header: {
                    Text("Your user info")
                } footer: {
                    Text("Sent to users who request your info.")
                }
            }
            .navigationTitle("Shares")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result, !urls.isEmpty else { return }
                for url in urls {
                    ShareBookmarks.shared.save(url: url)
                }
                client.setSharedDirectories(urls)
            }
            .onAppear {
                description = client.config.userInfoDescription
                if client.shares.sharedDirectories.isEmpty {
                    let restored = ShareBookmarks.shared.resolveAll()
                    if !restored.isEmpty {
                        client.shares.setSharedDirectories(restored)
                        client.rescanShares()
                    }
                }
            }
        }
    }

    private func saveDescription() {
        client.config.userInfoDescription = description
        client.saveConfig()
    }
}

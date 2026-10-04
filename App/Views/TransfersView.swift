import SwiftUI

struct TransfersView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var segment = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Direction", selection: $segment) {
                    Text("Downloads").tag(0)
                    Text("Uploads").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(8)
                .slskGlassSurface()
                .padding()

                if segment == 0 {
                    downloadList
                } else {
                    uploadList
                }
            }
            .slskScreen()
            .navigationTitle("Transfers")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if segment == 0 {
                            Button("Clear finished") {
                                client.transfers.clearFinishedDownloads()
                            }
                        }
                        Button("Save now") {
                            client.transfers.persist()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var downloadList: some View {
        List {
            let active = client.transfers.downloads.filter { $0.status.isActive }
            let done = client.transfers.downloads.filter { !$0.status.isActive }
            if !active.isEmpty {
                Section("Active") {
                    ForEach(active) { item in
                        TransferRow(item: item)
                            .contextMenu { downloadActions(item) }
                    }
                }
            }
            if !done.isEmpty {
                Section("History") {
                    ForEach(done) { item in
                        TransferRow(item: item)
                            .contextMenu { downloadActions(item) }
                    }
                }
            }
            if client.transfers.downloads.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No downloads yet")
                        Text("Find files with a search, then tap the download button.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var uploadList: some View {
        List {
            let active = client.transfers.uploads.filter { $0.status.isActive }
            let done = client.transfers.uploads.filter { !$0.status.isActive }
            if !active.isEmpty {
                Section("Active") {
                    ForEach(active) { item in
                        TransferRow(item: item)
                    }
                }
            }
            if !done.isEmpty {
                Section("History") {
                    ForEach(done) { item in
                        TransferRow(item: item)
                    }
                }
            }
            if client.transfers.uploads.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No uploads yet")
                        Text("Share folders from the Shares tab; upload slots: \(client.transfers.uploadSlots)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func downloadActions(_ item: DownloadItem) -> some View {
        if item.status == .finished {
            Button {
                client.transfers.retryDownload(item)
            } label: {
                Label("Download again", systemImage: "arrow.clockwise")
            }
        } else if !item.status.isActive {
            Button {
                client.transfers.retryDownload(item)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        } else {
            Button(role: .destructive) {
                client.transfers.cancelDownload(item)
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        }
        Button(role: .destructive) {
            client.transfers.removeDownload(item)
        } label: {
            Label("Remove from list", systemImage: "trash")
        }
        Button {
            client.banUser(item.username)
        } label: {
            Label("Ban \(item.username)", systemImage: "hand.raised")
        }
    }
}

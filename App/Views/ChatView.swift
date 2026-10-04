import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var segment = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Chat type", selection: $segment) {
                    Text("Rooms").tag(0)
                    Text("Private").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(8)
                .slskGlassSurface()
                .padding()

                if segment == 0 {
                    RoomsListView()
                } else {
                    PrivateMessagesListView()
                }
            }
            .slskScreen()
            .navigationTitle("Chat")
        }
    }
}

// MARK: - Rooms

struct RoomsListView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var joinName = ""

    var body: some View {
        List {
            if !client.chat.joinedRooms.isEmpty {
                Section("Joined rooms") {
                    ForEach(client.chat.joinedRooms) { room in
                        NavigationLink {
                            RoomChatView(room: room)
                        } label: {
                            HStack {
                                Text(room.name)
                                if room.isPrivate {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Text("\(room.users.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Join a room") {
                HStack {
                    TextField("Room name", text: $joinName)
                        .textInputAutocapitalization(.never)
                    Button("Join") {
                        let name = joinName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        client.joinRoom(name)
                        joinName = ""
                    }
                    .disabled(joinName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Public feed") {
                NavigationLink {
                    GlobalFeedView()
                } label: {
                    Label("All public rooms", systemImage: "dot.radiowaves.left.and.right")
                }
            }

            Section("All rooms") {
                let sorted = client.roomCounts.sorted { $0.value > $1.value }
                ForEach(sorted.prefix(100), id: \.key) { name, count in
                    Button {
                        client.joinRoom(name)
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct RoomChatView: View {
    @EnvironmentObject private var client: SoulseekClient
    @Environment(\.dismiss) private var dismiss
    let room: Room
    @State private var input = ""
    @State private var showMembers = false

    var body: some View {
        VStack(spacing: 0) {
            MessageList(messages: room.messages) { message in
                MessageBubble(message: message)
            }
            MessageInput(placeholder: "Message #\(room.name)") { text in
                client.say(room: room.name, text)
            }
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showMembers = true
                } label: {
                    Image(systemName: "person.3")
                }
            }
        }
        .sheet(isPresented: $showMembers) {
            RoomMembersSheet(room: room)
        }
    }
}

struct RoomMembersSheet: View {
    @EnvironmentObject private var client: SoulseekClient
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var roomHolder: RoomObserver
    @State private var ticker = ""

    init(room: Room) {
        roomHolder = RoomObserver(room: room)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Tickers") {
                    ForEach(roomHolder.room.tickers, id: \.username) { ticker in
                        VStack(alignment: .leading) {
                            Text(ticker.username).font(.caption)
                            Text(ticker.message).font(.footnote)
                        }
                    }
                    HStack {
                        TextField("Set your ticker", text: $ticker)
                        Button("Set") {
                            client.setRoomTicker(room: roomHolder.room.name, message: ticker)
                            ticker = ""
                        }
                    }
                }
                Section("Members (\(roomHolder.room.users.count))") {
                    ForEach(roomHolder.room.users, id: \.self) { user in
                        NavigationLink {
                            UserSheet(username: user)
                        } label: {
                            HStack {
                                StatusDot(status: client.users[user]?.status ?? 0)
                                Text(user)
                                if roomHolder.room.owner == user {
                                    Image(systemName: "crown.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                if roomHolder.room.operators.contains(user) {
                                    Image(systemName: "checkmark.shield.fill")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .slskScreen()
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Leave room") {
                        client.leaveRoom(roomHolder.room.name)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
    }
}

/// Wrapper so sheets observe mutations of a `Room` instance.
final class RoomObserver: ObservableObject {
    let room: Room
    private var timer: Timer?

    init(room: Room) {
        self.room = room
        timer = Timer(fire: Date().addingTimeInterval(1), interval: 1, repeats: true) { [weak self] _ in
            self?.objectWillChange.send()
        }
        RunLoop.main.add(timer!, forMode: .default)
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Private messages

struct PrivateMessagesListView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var newUser = ""

    var body: some View {
        List {
            Section("Start a conversation") {
                HStack {
                    TextField("Username", text: $newUser)
                        .textInputAutocapitalization(.never)
                    NavigationLink("Message") {
                        PrivateChatView(username: newUser)
                    }
                    .disabled(newUser.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Conversations") {
                ForEach(client.chat.privateThreadsList(), id: \.self) { username in
                    NavigationLink {
                        PrivateChatView(username: username)
                    } label: {
                        HStack {
                            StatusDot(status: client.users[username]?.status ?? 0)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(username)
                                if let last = client.chat.messages(for: username).last {
                                    Text(last.text)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            client.clearPrivateThread(username: username)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            if client.chat.privateThreadsList().isEmpty {
                Section {
                    Text("No conversations yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PrivateChatView: View {
    @EnvironmentObject private var client: SoulseekClient
    let username: String
    @State private var input = ""
    @State private var showUserSheet = false

    var body: some View {
        VStack(spacing: 0) {
            MessageList(messages: client.chat.messages(for: username)) { message in
                MessageBubble(message: message)
            }
            MessageInput(placeholder: "Message \(username)") { text in
                client.sendMessage(to: username, text)
            }
        }
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showUserSheet = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showUserSheet) {
            UserSheet(username: username)
        }
    }
}

// MARK: - Public feed

struct GlobalFeedView: View {
    @EnvironmentObject private var client: SoulseekClient

    var body: some View {
        VStack(spacing: 0) {
            MessageList(messages: client.chat.globalRoomMessages) { message in
                MessageBubble(message: message)
            }
            HStack {
                Button(client.chat.globalRoomMessages.isEmpty ? "Enable feed" : "Disable feed") {
                    if client.chat.globalRoomMessages.isEmpty {
                        client.joinGlobalRoomFeed()
                    } else {
                        client.leaveGlobalRoomFeed()
                    }
                }
                .slskGlassButton()
            }
            .padding()
        }
        .navigationTitle("Public feed")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared chat components

struct MessageList<Message: View>: View {
    let messages: [ChatMessage]
    let bubble: (ChatMessage) -> Message

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background { SlskBackdrop() }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isSelf { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if !message.isSelf {
                        Text(message.username)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(message.isSelf ? Color.orange.opacity(0.25) : Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            if !message.isSelf { Spacer(minLength: 40) }
        }
    }
}

struct MessageInput: View {
    let placeholder: String
    let onSend: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .padding(8)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .focused($focused)
            Button {
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return }
                onSend(message)
                text = ""
            } label: {
                Image(systemName: "paperplane.fill")
                    .frame(minWidth: 24, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Send message")
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .slskGlassSurface(cornerRadius: 28)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

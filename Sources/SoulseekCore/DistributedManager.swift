import Foundation

/// Participation in the Soulseek distributed search network: parent/child
/// relationships, branch level/root tracking and search forwarding, following
/// Nicotine+'s algorithm.
public final class DistributedManager {
    public var localUsername = ""
    public private(set) var parentUsername: String?
    public private(set) var branchLevel: UInt32 = 0
    public private(set) var branchRoot: String?
    public private(set) var children: Set<String> = []
    public private(set) var parentCandidates: [(username: String, host: String, port: UInt16)] = []

    public var parentMinSpeed: UInt32 = 0
    public var parentSpeedRatio: UInt32 = 0
    public var uploadSpeed: UInt32 = 0

    public var maxChildren: Int {
        guard parentSpeedRatio > 0, uploadSpeed >= parentMinSpeed else { return 0 }
        return min(Int(uploadSpeed / parentSpeedRatio / 100), 10)
    }

    /// Search requests arriving from our parent / the server get forwarded raw
    /// to children and answered locally by the client.
    public var onDistributedSearch: ((_ username: String, _ token: UInt32, _ query: String, _ connectionID: UInt64) -> Void)?
    public var onSendToServer: ((Data) -> Void)?
    public var onSendToConnection: ((UInt64, Data) -> Void)?
    public var onBranchChanged: (() -> Void)?

    public init() {}

    /// Sent after login: no parent yet, we announce ourselves as a branch root.
    public func announceInitialState() {
        parentUsername = nil
        branchLevel = 0
        branchRoot = localUsername
        candidateLevels.removeAll()
        candidateRoots.removeAll()
        children.removeAll()
        parentCandidates.removeAll()
        onSendToServer?(ServerOut.haveNoParent(true))
        onSendToServer?(ServerOut.branchLevel(0))
        onSendToServer?(ServerOut.branchRoot(localUsername))
        onBranchChanged?()
    }

    public func handlePossibleParents(_ candidates: [(username: String, host: String, port: UInt16)],
                                      connect: (String, String, UInt16) -> Void) {
        guard parentUsername == nil else { return }
        parentCandidates = candidates
        for candidate in candidates {
            connect(candidate.username, candidate.host, candidate.port)
        }
    }

    public func rejectParentCandidates() {
        parentCandidates.removeAll()
    }

    /// Distributed messages from a 'D' connection. Returns data to forward to
    /// all children (search requests are relayed unmodified).
    public func handleDistribMessage(code: UInt8, body: MessageBuffer, from username: String,
                                     connectionID: UInt64, isParentCandidate: Bool) -> [UInt8]? {
        var body = body
        switch code {
        case DistribCode.distribBranchLevel.rawValue:
            guard let level = try? body.readInt32(), level >= 0, level < Int32.max else { return nil }
            if username == parentUsername {
                branchLevel = UInt32(level + 1)
                onSendToServer?(ServerOut.branchLevel(branchLevel))
                pushBranchInfoToChildren()
                onBranchChanged?()
            }
            if isParentCandidate {
                candidateLevels[username] = Int32(level)
            }
            // A branch level of 0 marks the sender as branch root.
            if Int32(level) == 0, parentUsername == nil, isParentCandidate {
                candidateRoots[username] = username
            }
            return nil

        case DistribCode.distribBranchRoot.rawValue:
            guard let root = try? body.readString() else { return nil }
            if username == parentUsername {
                branchRoot = root
                onSendToServer?(ServerOut.branchRoot(root))
                pushBranchInfoToChildren()
                onBranchChanged?()
            }
            if isParentCandidate {
                candidateRoots[username] = root
            }
            return nil

        case DistribCode.distribSearch.rawValue:
            return handleDistribSearch(body: body, from: username, connectionID: connectionID)

        case DistribCode.distribPing.rawValue:
            return nil

        default:
            return nil
        }
    }

    /// DistribSearch body: uint32 identifier (ASCII 1 → 49), username, token, query.
    private func handleDistribSearch(body: MessageBuffer, from username: String,
                                     connectionID: UInt64) -> [UInt8]? {
        var buffer = body
        guard let identifier = try? buffer.readUInt32(), identifier == 49,
              let searcher = try? buffer.readString(),
              let token = try? buffer.readUInt32(),
              let query = try? buffer.readString() else { return nil }

        // First search from a candidate that also sent branch info adopts them.
        if parentUsername == nil, let level = candidateLevels[username], let root = candidateRoots[username] {
            adoptParent(username: username, level: level, root: root)
        }

        guard username == "server" || username == parentUsername else { return nil }

        onDistributedSearch?(searcher, token, query, connectionID)
        // Forward the raw message (identifier included) to our children.
        return body.bytes
    }

    private var candidateLevels: [String: Int32] = [:]
    private var candidateRoots: [String: String] = [:]

    private func adoptParent(username: String, level: Int32, root: String) {
        parentUsername = username
        branchLevel = UInt32(max(0, level + 1))
        branchRoot = root
        candidateLevels.removeAll()
        candidateRoots.removeAll()
        parentCandidates.removeAll()

        onSendToServer?(ServerOut.haveNoParent(false))
        onSendToServer?(ServerOut.branchRoot(root))
        onSendToServer?(ServerOut.branchLevel(branchLevel))
        pushBranchInfoToChildren()
        onBranchChanged?()
    }

    /// A new child connected ('D' PeerInit accepted): send our branch info on
    /// that connection.
    public func handleChildConnected(_ username: String, connectionID: UInt64) {
        children.insert(username)
        if let branchRoot {
            onSendToConnection?(connectionID, DistribOut.branchRoot(branchRoot))
        }
        onSendToConnection?(connectionID, DistribOut.branchLevel(Int32(bitPattern: branchLevel)))
    }

    public func handleChildDisconnected(_ username: String) {
        children.remove(username)
        candidateLevels[username] = nil
        candidateRoots[username] = nil
        if parentUsername == username {
            parentUsername = nil
            branchLevel = 0
            branchRoot = localUsername
            onSendToServer?(ServerOut.haveNoParent(true))
            onSendToServer?(ServerOut.branchRoot(localUsername))
            onSendToServer?(ServerOut.branchLevel(0))
            pushBranchInfoToChildren()
        }
        onBranchChanged?()
    }

    public func pushBranchInfoToChildren() {
        if let branchRoot {
            sendToChildren(DistribOut.branchRoot(branchRoot))
        }
        sendToChildren(DistribOut.branchLevel(Int32(bitPattern: branchLevel)))
    }

    private func sendToChildren(_ data: Data) {
        onSendToChildren?(data)
    }

    public var onSendToChildren: ((Data) -> Void)?

    /// Server asked us to reset the distributed state (ResetDistributed).
    public func reset() {
        announceInitialState()
    }

    /// We became branch root (server sends EmbeddedMessage searches to us).
    public func becomeBranchRoot() {
        parentUsername = nil
        branchLevel = 0
        branchRoot = localUsername
        candidateLevels.removeAll()
        candidateRoots.removeAll()
        onSendToServer?(ServerOut.branchLevel(0))
        onSendToServer?(ServerOut.branchRoot(localUsername))
        pushBranchInfoToChildren()
        onBranchChanged?()
    }
}

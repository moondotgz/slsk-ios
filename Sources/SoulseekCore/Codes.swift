import Foundation

/// Server message codes (`SERVER_MESSAGE_CODES` in Nicotine+).
public enum ServerCode {
    public static let login: UInt32 = 1
    public static let setWaitPort: UInt32 = 2
    public static let getPeerAddress: UInt32 = 3
    public static let watchUser: UInt32 = 5
    public static let unwatchUser: UInt32 = 6
    public static let getUserStatus: UInt32 = 7
    public static let sayChatroom: UInt32 = 13
    public static let joinRoom: UInt32 = 14
    public static let leaveRoom: UInt32 = 15
    public static let userJoinedRoom: UInt32 = 16
    public static let userLeftRoom: UInt32 = 17
    public static let connectToPeer: UInt32 = 18
    public static let messageUser: UInt32 = 22
    public static let messageAcked: UInt32 = 23
    public static let fileSearch: UInt32 = 26
    public static let setStatus: UInt32 = 28
    public static let serverPing: UInt32 = 32
    public static let sharedFoldersFiles: UInt32 = 35
    public static let getUserStats: UInt32 = 36
    public static let relogged: UInt32 = 41
    public static let userSearch: UInt32 = 42
    public static let addThingILike: UInt32 = 51
    public static let removeThingILike: UInt32 = 52
    public static let recommendations: UInt32 = 54
    public static let globalRecommendations: UInt32 = 56
    public static let userInterests: UInt32 = 57
    public static let roomList: UInt32 = 64
    public static let adminMessage: UInt32 = 66
    public static let privilegedUsers: UInt32 = 69
    public static let haveNoParent: UInt32 = 71
    public static let parentMinSpeed: UInt32 = 83
    public static let parentSpeedRatio: UInt32 = 84
    public static let checkPrivileges: UInt32 = 92
    public static let embeddedMessage: UInt32 = 93
    public static let acceptChildren: UInt32 = 100
    public static let possibleParents: UInt32 = 102
    public static let wishlistSearch: UInt32 = 103
    public static let wishlistInterval: UInt32 = 104
    public static let similarUsers: UInt32 = 110
    public static let itemRecommendations: UInt32 = 111
    public static let itemSimilarUsers: UInt32 = 112
    public static let roomTickers: UInt32 = 113
    public static let roomTickerAdded: UInt32 = 114
    public static let roomTickerRemoved: UInt32 = 115
    public static let setRoomTicker: UInt32 = 116
    public static let addThingIHate: UInt32 = 117
    public static let removeThingIHate: UInt32 = 118
    public static let roomSearch: UInt32 = 120
    public static let sendUploadSpeed: UInt32 = 121
    public static let givePrivileges: UInt32 = 123
    public static let branchLevel: UInt32 = 126
    public static let branchRoot: UInt32 = 127
    public static let resetDistributed: UInt32 = 130
    public static let roomMembers: UInt32 = 133
    public static let addRoomMember: UInt32 = 134
    public static let removeRoomMember: UInt32 = 135
    public static let cancelRoomMembership: UInt32 = 136
    public static let cancelRoomOwnership: UInt32 = 137
    public static let roomMembershipGranted: UInt32 = 139
    public static let roomMembershipRevoked: UInt32 = 140
    public static let enableRoomInvitations: UInt32 = 141
    public static let changePassword: UInt32 = 142
    public static let addRoomOperator: UInt32 = 143
    public static let removeRoomOperator: UInt32 = 144
    public static let roomOperatorshipGranted: UInt32 = 145
    public static let roomOperatorshipRevoked: UInt32 = 146
    public static let roomOperators: UInt32 = 148
    public static let joinGlobalRoom: UInt32 = 150
    public static let leaveGlobalRoom: UInt32 = 151
    public static let globalRoomMessage: UInt32 = 152
    public static let excludedSearchPhrases: UInt32 = 160
    public static let cantConnectToPeer: UInt32 = 1001
    public static let cantCreateRoom: UInt32 = 1003
}

/// Peer-init message codes (1-byte codes).
public enum PeerInitCode: UInt8 {
    case pierceFirewall = 0
    case peerInit = 1
}

/// Peer message codes (4-byte codes).
public enum PeerCode {
    public static let sharedFileListRequest: UInt32 = 4
    public static let sharedFileListResponse: UInt32 = 5
    public static let fileSearchResponse: UInt32 = 9
    public static let userInfoRequest: UInt32 = 15
    public static let userInfoResponse: UInt32 = 16
    public static let folderContentsRequest: UInt32 = 36
    public static let folderContentsResponse: UInt32 = 37
    public static let transferRequest: UInt32 = 40
    public static let transferResponse: UInt32 = 41
    public static let queueUpload: UInt32 = 43
    public static let placeInQueueResponse: UInt32 = 44
    public static let uploadFailed: UInt32 = 46
    public static let uploadDenied: UInt32 = 50
    public static let placeInQueueRequest: UInt32 = 51
}

/// Distributed message codes (1-byte codes).
public enum DistribCode: UInt8 {
    case distribPing = 0
    case distribSearch = 3
    case distribBranchLevel = 4
    case distribBranchRoot = 5
    case distribChildDepth = 7
    case distribEmbeddedMessage = 93
}

public enum ConnectionType {
    public static let peer = "P"
    public static let file = "F"
    public static let distributed = "D"
}

public enum TransferDirection {
    /// Legacy download request (QueueUpload replaces it).
    public static let download: UInt32 = 0
    public static let upload: UInt32 = 1
}

public enum TransferRejectReason {
    public static let queued = "Queued"
    public static let complete = "Complete"
    public static let cancelled = "Cancelled"
    public static let fileReadError = "File read error."
    public static let fileNotShared = "File not shared."
    public static let banned = "Banned"
    public static let tooManyFiles = "Too many files"
    public static let tooManyMegabytes = "Too many megabytes"
    public static let disallowedExtension = "Disallowed extension"
}

public enum UserStatusValue {
    public static let offline: UInt32 = 0
    public static let away: UInt32 = 1
    public static let online: UInt32 = 2
}

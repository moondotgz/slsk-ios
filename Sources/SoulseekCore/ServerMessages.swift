import Foundation

/// Builders for outgoing server messages. Each function returns a complete,
/// framed packet ready to be sent over the server connection.
public enum ServerOut {
    /// Nicotine+ docstring: experimental clients may use major version 177
    /// with any minor version. The checksum is `md5(username + password)`;
    /// the password itself travels as a plain string (a known quirk of the
    /// legacy protocol).
    public static let majorVersion: UInt32 = 177
    public static let minorVersion: UInt32 = 1

    public static func login(username: String, password: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        b.writeString(password)
        b.writeUInt32(majorVersion)
        b.writeString(MD5.hexDigest(username + password))
        b.writeUInt32(minorVersion)
        return Frame.server(code: ServerCode.login, payload: b.bytes)
    }

    public static func setWaitPort(_ port: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(port)
        return Frame.server(code: ServerCode.setWaitPort, payload: b.bytes)
    }

    public static func getPeerAddress(_ username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        return Frame.server(code: ServerCode.getPeerAddress, payload: b.bytes)
    }

    public static func watchUser(_ username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        return Frame.server(code: ServerCode.watchUser, payload: b.bytes)
    }

    public static func unwatchUser(_ username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        return Frame.server(code: ServerCode.unwatchUser, payload: b.bytes)
    }

    public static func getUserStatus(_ username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        return Frame.server(code: ServerCode.getUserStatus, payload: b.bytes)
    }

    public static func getUserStats(_ username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        return Frame.server(code: ServerCode.getUserStats, payload: b.bytes)
    }

    public static func sayChatroom(room: String, message: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        b.writeString(message)
        return Frame.server(code: ServerCode.sayChatroom, payload: b.bytes)
    }

    public static func joinRoom(_ room: String, isPrivate: Bool) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        b.writeUInt32(isPrivate ? 1 : 0)
        return Frame.server(code: ServerCode.joinRoom, payload: b.bytes)
    }

    public static func leaveRoom(_ room: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        return Frame.server(code: ServerCode.leaveRoom, payload: b.bytes)
    }

    public static func connectToPeer(token: UInt32, username: String, type: String) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(token)
        b.writeString(username)
        b.writeString(type)
        return Frame.server(code: ServerCode.connectToPeer, payload: b.bytes)
    }

    public static func messageUser(username: String, message: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        b.writeString(message)
        return Frame.server(code: ServerCode.messageUser, payload: b.bytes)
    }

    public static func messageAcked(_ id: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(id)
        return Frame.server(code: ServerCode.messageAcked, payload: b.bytes)
    }

    public static func fileSearch(token: UInt32, query: String) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(token)
        b.writeString(query)
        return Frame.server(code: ServerCode.fileSearch, payload: b.bytes)
    }

    public static func userSearch(username: String, token: UInt32, query: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        b.writeUInt32(token)
        b.writeString(query)
        return Frame.server(code: ServerCode.userSearch, payload: b.bytes)
    }

    public static func roomSearch(room: String, token: UInt32, query: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        b.writeUInt32(token)
        b.writeString(query)
        return Frame.server(code: ServerCode.roomSearch, payload: b.bytes)
    }

    public static func setStatus(_ status: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeInt32(Int32(bitPattern: status))
        return Frame.server(code: ServerCode.setStatus, payload: b.bytes)
    }

    public static func serverPing() -> Data {
        Frame.server(code: ServerCode.serverPing)
    }

    public static func sharedFoldersFiles(folders: UInt32, files: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(folders)
        b.writeUInt32(files)
        return Frame.server(code: ServerCode.sharedFoldersFiles, payload: b.bytes)
    }

    public static func addThingILike(_ thing: String) -> Data {
        var b = MessageBuffer()
        b.writeString(thing)
        return Frame.server(code: ServerCode.addThingILike, payload: b.bytes)
    }

    public static func removeThingILike(_ thing: String) -> Data {
        var b = MessageBuffer()
        b.writeString(thing)
        return Frame.server(code: ServerCode.removeThingILike, payload: b.bytes)
    }

    public static func addThingIHate(_ thing: String) -> Data {
        var b = MessageBuffer()
        b.writeString(thing)
        return Frame.server(code: ServerCode.addThingIHate, payload: b.bytes)
    }

    public static func removeThingIHate(_ thing: String) -> Data {
        var b = MessageBuffer()
        b.writeString(thing)
        return Frame.server(code: ServerCode.removeThingIHate, payload: b.bytes)
    }

    public static func recommendationsRequest() -> Data {
        Frame.server(code: ServerCode.recommendations)
    }

    public static func globalRecommendationsRequest() -> Data {
        Frame.server(code: ServerCode.globalRecommendations)
    }

    public static func itemRecommendationsRequest(_ item: String) -> Data {
        var b = MessageBuffer()
        b.writeString(item)
        return Frame.server(code: ServerCode.itemRecommendations, payload: b.bytes)
    }

    public static func similarUsersRequest() -> Data {
        Frame.server(code: ServerCode.similarUsers)
    }

    public static func itemSimilarUsersRequest(_ item: String) -> Data {
        var b = MessageBuffer()
        b.writeString(item)
        return Frame.server(code: ServerCode.itemSimilarUsers, payload: b.bytes)
    }

    public static func userInterestsRequest(_ username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        return Frame.server(code: ServerCode.userInterests, payload: b.bytes)
    }

    public static func roomListRequest() -> Data {
        Frame.server(code: ServerCode.roomList)
    }

    public static func checkPrivileges() -> Data {
        Frame.server(code: ServerCode.checkPrivileges)
    }

    public static func haveNoParent(_ value: Bool) -> Data {
        var b = MessageBuffer()
        b.writeBool(value)
        return Frame.server(code: ServerCode.haveNoParent, payload: b.bytes)
    }

    public static func acceptChildren(_ value: Bool) -> Data {
        var b = MessageBuffer()
        b.writeBool(value)
        return Frame.server(code: ServerCode.acceptChildren, payload: b.bytes)
    }

    public static func branchLevel(_ level: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(level)
        return Frame.server(code: ServerCode.branchLevel, payload: b.bytes)
    }

    public static func branchRoot(_ username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        return Frame.server(code: ServerCode.branchRoot, payload: b.bytes)
    }

    public static func wishlistSearch(token: UInt32, query: String) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(token)
        b.writeString(query)
        return Frame.server(code: ServerCode.wishlistSearch, payload: b.bytes)
    }

    public static func setRoomTicker(room: String, message: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        b.writeString(message)
        return Frame.server(code: ServerCode.setRoomTicker, payload: b.bytes)
    }

    public static func sendUploadSpeed(_ speed: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(speed)
        return Frame.server(code: ServerCode.sendUploadSpeed, payload: b.bytes)
    }

    public static func givePrivileges(username: String, days: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        b.writeUInt32(days)
        return Frame.server(code: ServerCode.givePrivileges, payload: b.bytes)
    }

    public static func changePassword(_ password: String) -> Data {
        var b = MessageBuffer()
        b.writeString(password)
        return Frame.server(code: ServerCode.changePassword, payload: b.bytes)
    }

    public static func cantConnectToPeer(token: UInt32, username: String) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(token)
        b.writeString(username)
        return Frame.server(code: ServerCode.cantConnectToPeer, payload: b.bytes)
    }

    public static func addRoomMember(room: String, username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        b.writeString(username)
        return Frame.server(code: ServerCode.addRoomMember, payload: b.bytes)
    }

    public static func removeRoomMember(room: String, username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        b.writeString(username)
        return Frame.server(code: ServerCode.removeRoomMember, payload: b.bytes)
    }

    public static func cancelRoomMembership(room: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        return Frame.server(code: ServerCode.cancelRoomMembership, payload: b.bytes)
    }

    public static func cancelRoomOwnership(room: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        return Frame.server(code: ServerCode.cancelRoomOwnership, payload: b.bytes)
    }

    public static func enableRoomInvitations(_ enabled: Bool) -> Data {
        var b = MessageBuffer()
        b.writeBool(enabled)
        return Frame.server(code: ServerCode.enableRoomInvitations, payload: b.bytes)
    }

    public static func addRoomOperator(room: String, username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        b.writeString(username)
        return Frame.server(code: ServerCode.addRoomOperator, payload: b.bytes)
    }

    public static func removeRoomOperator(room: String, username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(room)
        b.writeString(username)
        return Frame.server(code: ServerCode.removeRoomOperator, payload: b.bytes)
    }

    public static func joinGlobalRoom() -> Data {
        Frame.server(code: ServerCode.joinGlobalRoom)
    }

    public static func leaveGlobalRoom() -> Data {
        Frame.server(code: ServerCode.leaveGlobalRoom)
    }
}

/// Builders for outgoing peer-init messages.
public enum PeerInitOut {
    public static func peerInit(username: String, type: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        b.writeString(type)
        b.writeUInt32(0)
        return Frame.initMessage(code: PeerInitCode.peerInit.rawValue, payload: b.bytes)
    }

    public static func pierceFirewall(token: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(token)
        return Frame.initMessage(code: PeerInitCode.pierceFirewall.rawValue, payload: b.bytes)
    }
}

/// Builders for outgoing peer messages.
public enum PeerOut {
    public static func sharedFileListRequest() -> Data {
        Frame.peer(code: PeerCode.sharedFileListRequest)
    }

    public static func userInfoRequest() -> Data {
        Frame.peer(code: PeerCode.userInfoRequest)
    }

    public static func folderContentsRequest(token: UInt32, directory: String) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(token)
        b.writeString(directory)
        return Frame.peer(code: PeerCode.folderContentsRequest, payload: b.bytes)
    }

    public static func transferRequest(direction: UInt32, token: UInt32, file: String, fileSize: UInt64? = nil) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(direction)
        b.writeUInt32(token)
        b.writeString(file)
        if direction == TransferDirection.upload, let fileSize {
            b.writeUInt64(fileSize)
        }
        return Frame.peer(code: PeerCode.transferRequest, payload: b.bytes)
    }

    public static func transferResponse(token: UInt32, allowed: Bool, reason: String? = nil, fileSize: UInt64? = nil) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(token)
        b.writeBool(allowed)
        if !allowed, let reason {
            b.writeString(reason)
        }
        if allowed, let fileSize {
            b.writeUInt64(fileSize)
        }
        return Frame.peer(code: PeerCode.transferResponse, payload: b.bytes)
    }

    public static func queueUpload(_ file: String) -> Data {
        var b = MessageBuffer()
        b.writeString(file)
        return Frame.peer(code: PeerCode.queueUpload, payload: b.bytes)
    }

    public static func placeInQueueResponse(file: String, place: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeString(file)
        b.writeUInt32(place)
        return Frame.peer(code: PeerCode.placeInQueueResponse, payload: b.bytes)
    }

    public static func placeInQueueRequest(_ file: String) -> Data {
        var b = MessageBuffer()
        b.writeString(file)
        return Frame.peer(code: PeerCode.placeInQueueRequest, payload: b.bytes)
    }

    public static func uploadFailed(_ file: String) -> Data {
        var b = MessageBuffer()
        b.writeString(file)
        return Frame.peer(code: PeerCode.uploadFailed, payload: b.bytes)
    }

    public static func uploadDenied(file: String, reason: String) -> Data {
        var b = MessageBuffer()
        b.writeString(file)
        b.writeString(reason)
        return Frame.peer(code: PeerCode.uploadDenied, payload: b.bytes)
    }

    public static func userInfoResponse(description: String, picture: Data?, totalUploads: UInt32,
                                        queueSize: UInt32, slotsAvailable: Bool, uploadAllowed: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeString(description)
        if let picture {
            b.writeBool(true)
            b.writeUInt32(UInt32(picture.count))
            b.writeData(picture)
        } else {
            b.writeBool(false)
        }
        b.writeUInt32(totalUploads)
        b.writeUInt32(queueSize)
        b.writeBool(slotsAvailable)
        b.writeUInt32(uploadAllowed)
        return Frame.peer(code: PeerCode.userInfoResponse, payload: b.bytes)
    }
}

/// Builders for outgoing distributed messages.
public enum DistribOut {
    public static func branchLevel(_ level: Int32) -> Data {
        var b = MessageBuffer()
        b.writeInt32(level)
        return Frame.distributed(code: DistribCode.distribBranchLevel.rawValue, payload: b.bytes)
    }

    public static func branchRoot(_ username: String) -> Data {
        var b = MessageBuffer()
        b.writeString(username)
        return Frame.distributed(code: DistribCode.distribBranchRoot.rawValue, payload: b.bytes)
    }

    public static func childDepth(_ depth: UInt32) -> Data {
        var b = MessageBuffer()
        b.writeUInt32(depth)
        return Frame.distributed(code: DistribCode.distribChildDepth.rawValue, payload: b.bytes)
    }
}

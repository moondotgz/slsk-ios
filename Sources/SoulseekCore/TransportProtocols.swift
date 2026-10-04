import Foundation

/// Transport abstraction: SoulseekCore contains all protocol logic and can be
/// unit-tested on Linux with mock streams; the iOS app implements the
/// protocols with Network.framework sockets.
///
/// Delegates are always invoked on the main queue by conforming transports.

public protocol ByteStream: AnyObject {
    var delegate: (any ByteStreamDelegate)? { get set }
    var identifier: UInt64 { get }
    /// Connect to `host:port` (nil host = already-connected socket, e.g. accepted
    /// by the listener) and send `initialBytes` immediately after connecting.
    func start(host: String?, port: UInt16, initialBytes: Data?)
    func send(_ data: Data)
    /// Completion runs on the main queue after the transport processes the bytes.
    func send(_ data: Data, completion: @escaping ((any Error)?) -> Void)
    func close()
}

public protocol ByteStreamDelegate: AnyObject {
    func byteStreamDidOpen(_ stream: any ByteStream)
    func byteStream(_ stream: any ByteStream, didReceive data: Data)
    func byteStream(_ stream: any ByteStream, didCloseWith error: (any Error)?)
    func byteStream(_ stream: any ByteStream, isWaitingWith error: any Error)
}

public extension ByteStreamDelegate {
    func byteStream(_ stream: any ByteStream, isWaitingWith error: any Error) {}
}

/// TCP listener for incoming peer connections. Binding completes
/// asynchronously; observe `boundPort` / `onPortBound`.
public protocol ListenerService: AnyObject {
    var delegate: (any ListenerServiceDelegate)? { get set }
    /// The port actually bound (0 while unbound). May differ from the
    /// requested port when it was unavailable and we fell back to ephemeral.
    var boundPort: UInt16 { get }
    var onPortBound: ((UInt16) -> Void)? { get set }
    func start(requestedPort: UInt16)
    func stop()
}

public protocol ListenerServiceDelegate: AnyObject {
    func listener(_ listener: any ListenerService, didAccept stream: any ByteStream)
    func listener(_ listener: any ListenerService, didFailWith error: any Error)
}

public protocol TransportFactory: AnyObject {
    func makeServerStream() -> any ByteStream
    func makePeerStream() -> any ByteStream
    func makeListener() -> any ListenerService
}

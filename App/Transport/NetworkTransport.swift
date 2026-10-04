import Foundation
import Network
import SoulseekCore

/// Network.framework implementation of the SoulseekCore transport protocols.
/// All delegate callbacks are delivered on the main queue.

final class TCPStream: ByteStream {
    let identifier: UInt64
    weak var delegate: (any ByteStreamDelegate)?

    private var connection: NWConnection?
    private var initialBytes: Data?
    private let queue: DispatchQueue
    private static let idLock = NSLock()
    private static var nextID: UInt64 = 0

    static func allocateID() -> UInt64 {
        idLock.lock()
        defer { idLock.unlock() }
        nextID += 1
        return nextID
    }

    /// Fresh outbound connection.
    init(queue: DispatchQueue? = nil) {
        identifier = TCPStream.allocateID()
        self.queue = queue ?? DispatchQueue(label: "slsk.stream.\(identifier)")
    }

    /// Already-connected socket (accepted by TCPListener).
    init(preConnected connection: NWConnection) {
        identifier = TCPStream.allocateID()
        queue = DispatchQueue(label: "slsk.stream.\(identifier)")
        self.connection = connection
    }

    func start(host: String?, port: UInt16, initialBytes: Data?) {
        self.initialBytes = initialBytes

        if let connection {
            attach(connection)
            return
        }
        guard let host else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let endpoint = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let newConnection = NWConnection(host: endpoint, port: nwPort, using: params)
        attach(newConnection)
    }

    private func attach(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    if let initialBytes = self.initialBytes {
                        self.initialBytes = nil
                        self.connection?.send(content: initialBytes, completion: .contentProcessed { _ in })
                    }
                    self.delegate?.byteStreamDidOpen(self)
                case .failed, .cancelled:
                    self.delegate?.byteStream(self, didCloseWith: state.error)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let data, !data.isEmpty {
                    self.delegate?.byteStream(self, didReceive: data)
                }
                if isComplete || error != nil {
                    self.delegate?.byteStream(self, didCloseWith: error)
                    self.connection = nil
                } else {
                    self.receiveNext()
                }
            }
        }
    }
}

final class TCPListener: ListenerService {
    weak var delegate: (any ListenerServiceDelegate)?
    var onPortBound: ((UInt16) -> Void)?
    private(set) var boundPort: UInt16 = 0

    private var listener: NWListener?
    private var requestedPort: UInt16 = 0

    func start(requestedPort: UInt16) {
        self.requestedPort = requestedPort
        createListener(port: requestedPort)
    }

    private func createListener(port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            bindFallback()
            return
        }

        let newListener = NWListener(using: params, on: nwPort)
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let stream = TCPStream(preConnected: connection)
            DispatchQueue.main.async {
                self.delegate?.listener(self, didAccept: stream)
            }
        }
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let bound = newListener.port?.rawValue ?? port
                DispatchQueue.main.async {
                    self.boundPort = bound
                    self.onPortBound?(bound)
                }
            case .failed:
                if port == self.requestedPort, self.requestedPort != 0 {
                    self.bindFallback()
                } else {
                    DispatchQueue.main.async {
                        self.delegate?.listener(self, didFailWith: state.error
                            ?? SlskError.connectionFailed("listener failed"))
                    }
                }
            default:
                break
            }
        }
        listener = newListener
        newListener.start(queue: DispatchQueue(label: "slsk.listener"))
    }

    private func bindFallback() {
        createListener(port: 0)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

final class TCPTransportFactory: TransportFactory {
    func makeServerStream() -> any ByteStream {
        TCPStream()
    }

    func makePeerStream() -> any ByteStream {
        TCPStream()
    }

    func makeListener() -> any ListenerService {
        TCPListener()
    }
}

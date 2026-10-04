import Foundation
import Network

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
                        self.send(initialBytes)
                    }
                    self.delegate?.byteStreamDidOpen(self)
                case .failed(let error):
                    self.delegate?.byteStream(self, didCloseWith: error)
                case .cancelled:
                    self.delegate?.byteStream(self, didCloseWith: nil)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ data: Data) {
        send(data) { [weak self] error in
            if let error, let self {
                self.delegate?.byteStream(self, didCloseWith: error)
                self.close()
            }
        }
    }

    func send(_ data: Data, completion: @escaping ((any Error)?) -> Void) {
        guard let connection else {
            completion(SlskError.notConnected)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            DispatchQueue.main.async { completion(error) }
        })
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
        let newListener: NWListener
        do {
            if port == 0 {
                newListener = try NWListener(using: params)
            } else if let nwPort = NWEndpoint.Port(rawValue: port) {
                newListener = try NWListener(using: params, on: nwPort)
            } else {
                bindFallback()
                return
            }
        } catch {
            if port != 0 {
                bindFallback()
            } else {
                delegate?.listener(self, didFailWith: error)
            }
            return
        }
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
            case .failed(let error):
                if port == self.requestedPort, self.requestedPort != 0 {
                    self.bindFallback()
                } else {
                    DispatchQueue.main.async {
                        self.delegate?.listener(self, didFailWith: error)
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

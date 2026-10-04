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
    private let keepAlive: Bool
    private var didOpen = false
    private static let idLock = NSLock()
    private static var nextID: UInt64 = 0

    static func allocateID() -> UInt64 {
        idLock.lock()
        defer { idLock.unlock() }
        nextID += 1
        return nextID
    }

    /// Fresh outbound connection.
    init(queue: DispatchQueue? = nil, keepAlive: Bool = false) {
        identifier = TCPStream.allocateID()
        self.keepAlive = keepAlive
        self.queue = queue ?? DispatchQueue(label: "slsk.stream.\(identifier)")
    }

    /// Already-connected socket (accepted by TCPListener).
    init(preConnected connection: NWConnection) {
        identifier = TCPStream.allocateID()
        keepAlive = false
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
        if keepAlive, let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 4
        }
        let endpoint = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let newConnection = NWConnection(host: endpoint, port: nwPort, using: params)
        attach(newConnection)
    }

    private func attach(_ connection: NWConnection) {
        self.connection = connection
        connection.pathUpdateHandler = { [weak self, weak connection] path in
            let description = "status=\(path.status), cellular=\(path.usesInterfaceType(.cellular)), wifi=\(path.usesInterfaceType(.wifi)), expensive=\(path.isExpensive)"
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                self.delegate?.byteStream(self, didUpdateNetworkPath: description)
            }
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    guard !self.didOpen else { return }
                    self.didOpen = true
                    if let initialBytes = self.initialBytes {
                        self.initialBytes = nil
                        self.send(initialBytes)
                    }
                    self.delegate?.byteStreamDidOpen(self)
                case .failed(let error):
                    self.finish(error: error)
                case .waiting(let error):
                    self.delegate?.byteStream(self, isWaitingWith: error)
                case .cancelled:
                    self.finish(error: nil)
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
        guard let connection else { return }
        self.connection = nil
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.byteStream(self, didCloseWith: nil)
        }
    }

    private func finish(error: (any Error)?) {
        guard let connection else { return }
        self.connection = nil
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
        delegate?.byteStream(self, didCloseWith: error)
    }

    private func receiveNext() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let connection, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.delegate?.byteStream(self, didReceive: data)
                }
                if isComplete || error != nil {
                    self.finish(error: error)
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
        TCPStream(keepAlive: true)
    }

    func makePeerStream() -> any ByteStream {
        TCPStream()
    }

    func makeListener() -> any ListenerService {
        TCPListener()
    }
}

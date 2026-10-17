import Foundation
import Network

/// Network.framework / URLSession implementation of `PortMappingTransport`.
/// Restricted to Wi-Fi: cellular carrier NAT cannot be mapped. All
/// completions are delivered on the main queue.
final class NetworkPortMappingTransport: PortMappingTransport {
    private let queue = DispatchQueue(label: "slsk.portmapping")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Calls `body` at most once; only touched on `queue`.
    private final class Once<Value> {
        private var done = false
        private let body: (Value) -> Void
        init(_ body: @escaping (Value) -> Void) { self.body = body }
        func callAsFunction(_ value: Value) {
            guard !done else { return }
            done = true
            body(value)
        }
    }

    func localNetwork(completion: @escaping ((gateway: String, localAddress: String)?) -> Void) {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let finish = Once<(gateway: String, localAddress: String)?> { result in
            monitor.cancel()
            DispatchQueue.main.async { completion(result) }
        }
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied,
                  let interface = path.availableInterfaces.first(where: { $0.type == .wifi }),
                  let gateway = path.gateways.lazy.compactMap(Self.ipv4Host).first,
                  let local = Self.ipv4Address(interfaceName: interface.name) else {
                finish(nil)
                return
            }
            finish((gateway, local))
        }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { finish(nil) }
    }

    func exchangeDatagram(_ data: Data, host: String, port: UInt16, timeout: TimeInterval,
                          completion: @escaping (Data?) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let finish = Once<Data?> { reply in
            connection.cancel()
            DispatchQueue.main.async { completion(reply) }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.receiveMessage { reply, _, _, error in
                    finish(error == nil ? reply : nil)
                }
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil { finish(nil) }
                })
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }

    func httpRequest(_ request: PortMappingHTTPRequest, completion: @escaping (Int, Data) -> Void) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        session.dataTask(with: urlRequest) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { completion(status, data ?? Data()) }
        }.resume()
    }

    private static func ipv4Host(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint, case let .ipv4(address) = host else { return nil }
        return address.rawValue.map { String($0) }.joined(separator: ".")
    }

    private static func ipv4Address(interfaceName: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == interfaceName else { continue }
            var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            return String(cString: buffer)
        }
        return nil
    }
}

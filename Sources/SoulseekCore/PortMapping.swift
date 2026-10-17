import Foundation

// MARK: - Transport

public struct PortMappingHTTPRequest: Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// Router-facing I/O used by `PortMapper`. Completions run on the main queue.
public protocol PortMappingTransport: AnyObject {
    /// IPv4 default gateway and this device's IPv4 address on the current
    /// Wi-Fi network, or nil when there is none (cellular NAT cannot be mapped).
    func localNetwork(completion: @escaping ((gateway: String, localAddress: String)?) -> Void)
    /// Sends one unicast datagram and returns the first reply, or nil on
    /// timeout or error.
    func exchangeDatagram(_ data: Data, host: String, port: UInt16, timeout: TimeInterval,
                          completion: @escaping (Data?) -> Void)
    /// Status is 0 when the request did not complete.
    func httpRequest(_ request: PortMappingHTTPRequest, completion: @escaping (Int, Data) -> Void)
}

public enum PortMappingStatus: Equatable {
    case disabled
    case idle
    case discovering
    case mapped(method: String, externalPort: UInt16)
    case unavailable(String)

    public var label: String {
        switch self {
        case .disabled: return "Off"
        case .idle: return "Not active"
        case .discovering: return "Searching for router…"
        case let .mapped(method, port): return "Forwarded via \(method) (port \(port))"
        case let .unavailable(reason): return reason
        }
    }
}

// MARK: - NAT-PMP (RFC 6886)

enum NATPMP {
    static let port: UInt16 = 5351
    static let tcpMapOpcode: UInt8 = 2

    struct MapResponse: Equatable {
        var resultCode: UInt16
        var internalPort: UInt16
        var externalPort: UInt16
        var lifetime: UInt32
    }

    /// Lifetime 0 with external port 0 deletes the mapping.
    static func mapTCPRequest(internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> Data {
        var data = Data([0, tcpMapOpcode, 0, 0])
        data.appendBigEndian(internalPort)
        data.appendBigEndian(externalPort)
        data.appendBigEndian(lifetime)
        return data
    }

    static func parseMapResponse(_ data: Data) -> MapResponse? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == 0, bytes[1] == tcpMapOpcode + 128 else { return nil }
        return MapResponse(resultCode: bytes.bigEndianUInt16(at: 2),
                           internalPort: bytes.bigEndianUInt16(at: 8),
                           externalPort: bytes.bigEndianUInt16(at: 10),
                           lifetime: bytes.bigEndianUInt32(at: 12))
    }
}

// MARK: - UPnP IGD

enum UPnPIGD {
    static let ssdpPort: UInt16 = 1900
    static let conflictInMappingEntry = 718
    static let onlyPermanentLeasesSupported = 725

    struct Service: Equatable {
        var serviceType: String
        var controlURL: URL
    }

    /// Sent unicast to the gateway: iOS requires a restricted entitlement for
    /// multicast. IGD:2 devices also answer IGD:1 searches.
    static func searchRequest() -> Data {
        Data(("M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 2\r\n"
            + "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n").utf8)
    }

    static func location(fromSearchResponse data: Data) -> URL? {
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("HTTP/1.0 200") else { return nil }
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "location" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return URL(string: value)
        }
        return nil
    }

    /// Picks the WAN connection service from a device description, preferring
    /// WANIPConnection over WANPPPConnection.
    static func connectionService(fromDescription data: Data, descriptionURL: URL) -> Service? {
        let xml = String(decoding: data, as: UTF8.self)
        let base = elementValue("URLBase", in: xml).flatMap { URL(string: $0) } ?? descriptionURL
        var candidates: [Service] = []
        var remainder = Substring(xml)
        while let start = remainder.range(of: "<service>"),
              let end = remainder.range(of: "</service>", range: start.upperBound..<remainder.endIndex) {
            let block = String(remainder[start.upperBound..<end.lowerBound])
            remainder = remainder[end.upperBound...]
            guard let type = elementValue("serviceType", in: block),
                  type.contains(":WANIPConnection:") || type.contains(":WANPPPConnection:"),
                  let control = elementValue("controlURL", in: block),
                  let url = URL(string: control, relativeTo: base)?.absoluteURL else { continue }
            candidates.append(Service(serviceType: type, controlURL: url))
        }
        return candidates.first { $0.serviceType.contains(":WANIPConnection:") } ?? candidates.first
    }

    static func addPortMappingRequest(service: Service, externalPort: UInt16, internalPort: UInt16,
                                      internalClient: String, leaseSeconds: UInt32) -> PortMappingHTTPRequest {
        soapRequest(service: service, action: "AddPortMapping", arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", "TCP"),
            ("NewInternalPort", String(internalPort)),
            ("NewInternalClient", internalClient),
            ("NewEnabled", "1"),
            ("NewPortMappingDescription", "Slsk"),
            ("NewLeaseDuration", String(leaseSeconds)),
        ])
    }

    static func deletePortMappingRequest(service: Service, externalPort: UInt16) -> PortMappingHTTPRequest {
        soapRequest(service: service, action: "DeletePortMapping", arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", "TCP"),
        ])
    }

    static func errorCode(fromFault data: Data) -> Int? {
        elementValue("errorCode", in: String(decoding: data, as: UTF8.self)).flatMap { Int($0) }
    }

    private static func soapRequest(service: Service, action: String,
                                    arguments: [(String, String)]) -> PortMappingHTTPRequest {
        let type = xmlEscaped(service.serviceType)
        let args = arguments.map { "<\($0.0)>\(xmlEscaped($0.1))</\($0.0)>" }.joined()
        let body = "<?xml version=\"1.0\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:\(action) xmlns:u=\"\(type)\">\(args)</u:\(action)>"
            + "</s:Body></s:Envelope>"
        return PortMappingHTTPRequest(url: service.controlURL, method: "POST", headers: [
            "Content-Type": "text/xml; charset=\"utf-8\"",
            "SOAPAction": "\"\(service.serviceType)#\(action)\"",
        ], body: Data(body.utf8))
    }

    private static func elementValue(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        let value = xml[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Mapper

/// Forwards the peer listener's TCP port on the local router: NAT-PMP first,
/// then UPnP IGD. Mappings are leased and renewed at half their lifetime.
public final class PortMapper {
    public private(set) var status: PortMappingStatus = .idle {
        didSet { if status != oldValue { onStatusChanged?(status) } }
    }
    public var onStatusChanged: ((PortMappingStatus) -> Void)?
    public var onDiagnostic: ((String) -> Void)?

    static let natpmpLifetime: UInt32 = 7200
    static let upnpLease: UInt32 = 3600
    static let natpmpTimeouts: [TimeInterval] = [1, 2]
    static let ssdpTimeout: TimeInterval = 3
    static let upnpPortAttempts = 3

    private enum Method {
        case natpmp(gateway: String)
        case upnp(UPnPIGD.Service)
    }

    private struct Mapping {
        var method: Method
        var internalPort: UInt16
        var externalPort: UInt16
    }

    private let transport: any PortMappingTransport
    private var generation = 0
    private var internalPort: UInt16 = 0
    private var mapping: Mapping?
    private var renewTimer: Timer?

    public init(transport: any PortMappingTransport) {
        self.transport = transport
    }

    deinit { renewTimer?.invalidate() }

    /// (Re)discovers the router and maps `internalPort`. Repeating a mapping
    /// for the same client and port renews it, so this is safe after every
    /// login or network change.
    public func start(internalPort: UInt16) {
        if let mapping, mapping.internalPort != internalPort {
            removeMapping(mapping)
            self.mapping = nil
        }
        renewTimer?.invalidate()
        renewTimer = nil
        generation += 1
        self.internalPort = internalPort
        status = .discovering
        discover(generation: generation)
    }

    /// Cancels pending work and deletes the current mapping (best effort).
    public func stop(status newStatus: PortMappingStatus = .idle) {
        generation += 1
        renewTimer?.invalidate()
        renewTimer = nil
        if let mapping { removeMapping(mapping) }
        mapping = nil
        status = newStatus
    }

    private func discover(generation: Int) {
        transport.localNetwork { [weak self] network in
            guard let self, generation == self.generation else { return }
            guard let network else {
                self.fail("Unavailable (not on Wi-Fi)", generation: generation)
                return
            }
            self.requestNATPMP(gateway: network.gateway, localAddress: network.localAddress,
                               attempt: 0, generation: generation)
        }
    }

    private func requestNATPMP(gateway: String, localAddress: String, attempt: Int, generation: Int) {
        let request = NATPMP.mapTCPRequest(internalPort: internalPort, externalPort: internalPort,
                                           lifetime: Self.natpmpLifetime)
        transport.exchangeDatagram(request, host: gateway, port: NATPMP.port,
                                   timeout: Self.natpmpTimeouts[attempt]) { [weak self] reply in
            guard let self, generation == self.generation else { return }
            guard let reply else {
                if attempt + 1 < Self.natpmpTimeouts.count {
                    self.requestNATPMP(gateway: gateway, localAddress: localAddress,
                                       attempt: attempt + 1, generation: generation)
                } else {
                    self.discoverUPnP(gateway: gateway, localAddress: localAddress, generation: generation)
                }
                return
            }
            guard let response = NATPMP.parseMapResponse(reply), response.resultCode == 0,
                  response.internalPort == self.internalPort, response.externalPort != 0 else {
                self.onDiagnostic?("Port mapping: NAT-PMP refused; trying UPnP")
                self.discoverUPnP(gateway: gateway, localAddress: localAddress, generation: generation)
                return
            }
            self.succeed(Mapping(method: .natpmp(gateway: gateway), internalPort: self.internalPort,
                                 externalPort: response.externalPort),
                         label: "NAT-PMP", lifetime: response.lifetime, generation: generation)
        }
    }

    private func discoverUPnP(gateway: String, localAddress: String, generation: Int) {
        transport.exchangeDatagram(UPnPIGD.searchRequest(), host: gateway, port: UPnPIGD.ssdpPort,
                                   timeout: Self.ssdpTimeout) { [weak self] reply in
            guard let self, generation == self.generation else { return }
            // Only talk to the gateway itself; a description elsewhere is not our router.
            guard let reply, let location = UPnPIGD.location(fromSearchResponse: reply),
                  location.host == gateway else {
                self.fail("Unavailable (router has no NAT-PMP or UPnP)", generation: generation)
                return
            }
            self.transport.httpRequest(PortMappingHTTPRequest(url: location)) { [weak self] status, body in
                guard let self, generation == self.generation else { return }
                guard status == 200,
                      let service = UPnPIGD.connectionService(fromDescription: body, descriptionURL: location),
                      service.controlURL.host == gateway else {
                    self.fail("Unavailable (UPnP router not usable)", generation: generation)
                    return
                }
                self.addUPnPMapping(service: service, localAddress: localAddress,
                                    externalPort: self.internalPort, lease: Self.upnpLease,
                                    attempt: 0, generation: generation)
            }
        }
    }

    private func addUPnPMapping(service: UPnPIGD.Service, localAddress: String, externalPort: UInt16,
                                lease: UInt32, attempt: Int, generation: Int) {
        let request = UPnPIGD.addPortMappingRequest(service: service, externalPort: externalPort,
                                                    internalPort: internalPort, internalClient: localAddress,
                                                    leaseSeconds: lease)
        transport.httpRequest(request) { [weak self] status, body in
            guard let self, generation == self.generation else { return }
            if status == 200 {
                self.succeed(Mapping(method: .upnp(service), internalPort: self.internalPort,
                                     externalPort: externalPort),
                             label: "UPnP", lifetime: lease, generation: generation)
                return
            }
            let code = UPnPIGD.errorCode(fromFault: body)
            if code == UPnPIGD.onlyPermanentLeasesSupported, lease != 0 {
                self.addUPnPMapping(service: service, localAddress: localAddress, externalPort: externalPort,
                                    lease: 0, attempt: attempt, generation: generation)
            } else if code == UPnPIGD.conflictInMappingEntry, attempt + 1 < Self.upnpPortAttempts,
                      externalPort < UInt16.max {
                self.addUPnPMapping(service: service, localAddress: localAddress, externalPort: externalPort + 1,
                                    lease: lease, attempt: attempt + 1, generation: generation)
            } else {
                self.fail("Unavailable (UPnP mapping refused\(code.map { ", error \($0)" } ?? ""))",
                          generation: generation)
            }
        }
    }

    private func succeed(_ newMapping: Mapping, label: String, lifetime: UInt32, generation: Int) {
        mapping = newMapping
        onDiagnostic?("Port mapping: \(label) forwarded TCP \(newMapping.internalPort) → external \(newMapping.externalPort), lifetime=\(lifetime)s")
        status = .mapped(method: label, externalPort: newMapping.externalPort)
        guard lifetime > 0 else { return }
        let interval = max(60, TimeInterval(lifetime) / 2)
        let timer = Timer(fire: Date().addingTimeInterval(interval), interval: 0, repeats: false) { [weak self] _ in
            guard let self, generation == self.generation else { return }
            self.renewTimer = nil
            self.discover(generation: generation)
        }
        RunLoop.main.add(timer, forMode: .default)
        renewTimer = timer
    }

    private func fail(_ reason: String, generation: Int) {
        guard generation == self.generation else { return }
        onDiagnostic?("Port mapping: \(reason)")
        mapping = nil
        status = .unavailable(reason)
    }

    private func removeMapping(_ mapping: Mapping) {
        switch mapping.method {
        case let .natpmp(gateway):
            let request = NATPMP.mapTCPRequest(internalPort: mapping.internalPort, externalPort: 0, lifetime: 0)
            transport.exchangeDatagram(request, host: gateway, port: NATPMP.port, timeout: 1) { _ in }
        case let .upnp(service):
            transport.httpRequest(UPnPIGD.deletePortMappingRequest(service: service,
                                                                   externalPort: mapping.externalPort)) { _, _ in }
        }
    }
}

// MARK: - Big-endian helpers (NAT-PMP is network byte order)

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
                            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}

private extension Array where Element == UInt8 {
    func bigEndianUInt16(at index: Int) -> UInt16 {
        UInt16(self[index]) << 8 | UInt16(self[index + 1])
    }

    func bigEndianUInt32(at index: Int) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16
            | UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
    }
}

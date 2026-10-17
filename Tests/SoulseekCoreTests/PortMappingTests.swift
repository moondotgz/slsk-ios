import Foundation
import XCTest
@testable import SoulseekCore

final class MockPortMappingTransport: PortMappingTransport {
    var network: (gateway: String, localAddress: String)? = ("192.168.1.1", "192.168.1.20")
    var datagramReply: (Data, String, UInt16) -> Data? = { _, _, _ in nil }
    var httpReply: (PortMappingHTTPRequest) -> (Int, Data) = { _ in (0, Data()) }
    var datagrams: [(data: Data, host: String, port: UInt16)] = []
    var requests: [PortMappingHTTPRequest] = []
    var networkQueries = 0

    func localNetwork(completion: @escaping ((gateway: String, localAddress: String)?) -> Void) {
        networkQueries += 1
        let network = network
        DispatchQueue.main.async { completion(network) }
    }

    func exchangeDatagram(_ data: Data, host: String, port: UInt16, timeout: TimeInterval,
                          completion: @escaping (Data?) -> Void) {
        datagrams.append((data, host, port))
        let reply = datagramReply(data, host, port)
        DispatchQueue.main.async { completion(reply) }
    }

    func httpRequest(_ request: PortMappingHTTPRequest, completion: @escaping (Int, Data) -> Void) {
        requests.append(request)
        let reply = httpReply(request)
        DispatchQueue.main.async { completion(reply.0, reply.1) }
    }
}

private enum Router {
    static let description = Data("""
        <?xml version="1.0"?>
        <root><device><serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
        <controlURL>/ctl/L3F</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
        <controlURL>/ctl/PPP</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        <controlURL>/ctl/IPConn</controlURL></service>
        </serviceList></device></root>
        """.utf8)

    static func ssdpReply(location: String) -> Data {
        Data("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLocation: \(location)\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n".utf8)
    }

    static func natpmpReply(result: UInt16 = 0, internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> Data {
        var bytes: [UInt8] = [0, 130, UInt8(result >> 8), UInt8(result & 0xFF), 0, 0, 0, 1]
        bytes += [UInt8(internalPort >> 8), UInt8(internalPort & 0xFF), UInt8(externalPort >> 8), UInt8(externalPort & 0xFF)]
        bytes += [UInt8(lifetime >> 24), UInt8((lifetime >> 16) & 0xFF), UInt8((lifetime >> 8) & 0xFF), UInt8(lifetime & 0xFF)]
        return Data(bytes)
    }

    static func fault(_ code: Int) -> Data {
        Data("<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>\(code)</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>".utf8)
    }
}

final class PortMappingCodecTests: XCTestCase {
    func testNATPMPRequestIsNetworkByteOrder() {
        let request = NATPMP.mapTCPRequest(internalPort: 2234, externalPort: 2234, lifetime: 7200)
        XCTAssertEqual([UInt8](request), [0, 2, 0, 0, 0x08, 0xBA, 0x08, 0xBA, 0, 0, 0x1C, 0x20])
    }

    func testNATPMPResponseParsing() {
        let reply = Router.natpmpReply(internalPort: 2234, externalPort: 40000, lifetime: 3600)
        XCTAssertEqual(NATPMP.parseMapResponse(reply),
                       NATPMP.MapResponse(resultCode: 0, internalPort: 2234, externalPort: 40000, lifetime: 3600))
        XCTAssertNil(NATPMP.parseMapResponse(reply.prefix(10)))
        var wrongOpcode = [UInt8](reply)
        wrongOpcode[1] = 129
        XCTAssertNil(NATPMP.parseMapResponse(Data(wrongOpcode)))
    }

    func testSSDPLocationHeaderIsCaseInsensitive() {
        let url = UPnPIGD.location(fromSearchResponse: Router.ssdpReply(location: "http://192.168.1.1:5000/rootDesc.xml"))
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.1:5000/rootDesc.xml")
        XCTAssertNil(UPnPIGD.location(fromSearchResponse: Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8)))
    }

    func testDescriptionPrefersWANIPConnectionAndResolvesRelativeControlURL() throws {
        let service = try XCTUnwrap(UPnPIGD.connectionService(
            fromDescription: Router.description,
            descriptionURL: URL(string: "http://192.168.1.1:5000/rootDesc.xml")!))
        XCTAssertEqual(service.serviceType, "urn:schemas-upnp-org:service:WANIPConnection:1")
        XCTAssertEqual(service.controlURL.absoluteString, "http://192.168.1.1:5000/ctl/IPConn")
    }

    func testDescriptionHonorsURLBase() throws {
        let xml = Data("<root><URLBase>http://10.0.0.1:49152/</URLBase><service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>upnp/control</controlURL></service></root>".utf8)
        let service = try XCTUnwrap(UPnPIGD.connectionService(
            fromDescription: xml, descriptionURL: URL(string: "http://10.0.0.1:1900/desc.xml")!))
        XCTAssertEqual(service.controlURL.absoluteString, "http://10.0.0.1:49152/upnp/control")
    }

    func testAddPortMappingSOAPRequest() throws {
        let service = UPnPIGD.Service(serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
                                      controlURL: URL(string: "http://192.168.1.1:5000/ctl/IPConn")!)
        let request = UPnPIGD.addPortMappingRequest(service: service, externalPort: 2234, internalPort: 2234,
                                                    internalClient: "192.168.1.20", leaseSeconds: 3600)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["SOAPAction"], "\"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"")
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains("<u:AddPortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">"))
        XCTAssertTrue(body.contains("<NewExternalPort>2234</NewExternalPort><NewProtocol>TCP</NewProtocol>"))
        XCTAssertTrue(body.contains("<NewInternalClient>192.168.1.20</NewInternalClient>"))
        XCTAssertTrue(body.contains("<NewLeaseDuration>3600</NewLeaseDuration>"))
        XCTAssertEqual(UPnPIGD.errorCode(fromFault: Router.fault(718)), 718)
    }
}

final class PortMapperTests: XCTestCase {
    private func pump(_ seconds: Double = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Router without NAT-PMP that serves a UPnP IGD description.
    private func upnpRouter(_ transport: MockPortMappingTransport, addReply: @escaping (String) -> (Int, Data)) {
        transport.datagramReply = { _, _, port in
            port == UPnPIGD.ssdpPort ? Router.ssdpReply(location: "http://192.168.1.1:5000/rootDesc.xml") : nil
        }
        transport.httpReply = { request in
            if request.method == "GET" { return (200, Router.description) }
            return addReply(String(decoding: request.body ?? Data(), as: UTF8.self))
        }
    }

    func testNATPMPMappingReportsRouterAssignedExternalPort() {
        let transport = MockPortMappingTransport()
        transport.datagramReply = { _, host, port in
            XCTAssertEqual(host, "192.168.1.1")
            XCTAssertEqual(port, NATPMP.port)
            return Router.natpmpReply(internalPort: 2234, externalPort: 50000, lifetime: 7200)
        }
        let mapper = PortMapper(transport: transport)
        var statuses: [PortMappingStatus] = []
        mapper.onStatusChanged = { statuses.append($0) }
        mapper.start(internalPort: 2234)
        pump()
        XCTAssertEqual(statuses, [.discovering, .mapped(method: "NAT-PMP", externalPort: 50000)])
        XCTAssertTrue(transport.requests.isEmpty, "UPnP is not tried when NAT-PMP succeeds")

        mapper.stop()
        let delete = transport.datagrams.last
        XCTAssertEqual(delete.map { [UInt8]($0.data) }, [0, 2, 0, 0, 0x08, 0xBA, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(mapper.status, .idle)
    }

    func testFallsBackToUPnPAfterNATPMPTimesOut() throws {
        let transport = MockPortMappingTransport()
        upnpRouter(transport) { _ in (200, Data()) }
        let mapper = PortMapper(transport: transport)
        mapper.start(internalPort: 2234)
        pump()
        XCTAssertEqual(mapper.status, .mapped(method: "UPnP", externalPort: 2234))
        XCTAssertEqual(transport.datagrams.filter { $0.port == NATPMP.port }.count, PortMapper.natpmpTimeouts.count)
        let add = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(add.url.absoluteString, "http://192.168.1.1:5000/ctl/IPConn")
        XCTAssertTrue(String(decoding: add.body ?? Data(), as: UTF8.self).contains("<NewInternalClient>192.168.1.20</NewInternalClient>"))

        mapper.stop()
        XCTAssertEqual(transport.requests.last?.headers["SOAPAction"],
                       "\"urn:schemas-upnp-org:service:WANIPConnection:1#DeletePortMapping\"")
    }

    func testUPnPRetriesPermanentLeaseAndConflictingPorts() {
        let transport = MockPortMappingTransport()
        upnpRouter(transport) { body in
            if body.contains("<NewLeaseDuration>3600</NewLeaseDuration>") { return (500, Router.fault(725)) }
            if body.contains("<NewExternalPort>2234</NewExternalPort>") { return (500, Router.fault(718)) }
            return (200, Data())
        }
        let mapper = PortMapper(transport: transport)
        mapper.start(internalPort: 2234)
        pump()
        XCTAssertEqual(mapper.status, .mapped(method: "UPnP", externalPort: 2235))
    }

    func testRejectsDescriptionHostedOffTheGateway() {
        let transport = MockPortMappingTransport()
        transport.datagramReply = { _, _, port in
            port == UPnPIGD.ssdpPort ? Router.ssdpReply(location: "http://203.0.113.9/rootDesc.xml") : nil
        }
        let mapper = PortMapper(transport: transport)
        mapper.start(internalPort: 2234)
        pump()
        XCTAssertTrue(transport.requests.isEmpty)
        guard case .unavailable = mapper.status else { return XCTFail("unexpected \(mapper.status)") }
    }

    func testWithoutWiFiReportsUnavailable() {
        let transport = MockPortMappingTransport()
        transport.network = nil
        let mapper = PortMapper(transport: transport)
        mapper.start(internalPort: 2234)
        pump()
        XCTAssertEqual(mapper.status, .unavailable("Unavailable (not on Wi-Fi)"))
        XCTAssertTrue(transport.datagrams.isEmpty)
    }

    func testStopIgnoresLateReplies() {
        let transport = MockPortMappingTransport()
        transport.datagramReply = { _, _, _ in Router.natpmpReply(internalPort: 2234, externalPort: 2234, lifetime: 7200) }
        let mapper = PortMapper(transport: transport)
        mapper.start(internalPort: 2234)
        mapper.stop()
        pump()
        XCTAssertEqual(mapper.status, .idle)
    }
}

private final class PortMappingFactory: TransportFactory {
    let base = MockTransportFactory()
    let transport = MockPortMappingTransport()
    func makeServerStream() -> any ByteStream { base.makeServerStream() }
    func makePeerStream() -> any ByteStream { base.makePeerStream() }
    func makeListener() -> any ListenerService { base.makeListener() }
    func makePortMappingTransport() -> (any PortMappingTransport)? { transport }
}

final class PortMappingClientTests: XCTestCase {
    private func pump(_ seconds: Double = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitPorts(_ stream: MockStream) -> [UInt32] {
        stream.sentFrames.compactMap { frame in
            var buffer = MessageBuffer(frame)
            guard (try? buffer.readUInt32()) != nil, (try? buffer.readUInt32()) == ServerCode.setWaitPort else { return nil }
            return try? buffer.readUInt32()
        }
    }

    func testMappedExternalPortIsAdvertisedAndDisablingRestoresListenPort() throws {
        let factory = PortMappingFactory()
        factory.transport.datagramReply = { _, _, _ in
            Router.natpmpReply(internalPort: 2234, externalPort: 41000, lifetime: 7200)
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slsk-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = ClientConfiguration()
        config.username = "tester"
        config.password = "secret"
        let client = SoulseekClient(factory: factory, storage: Storage(baseURL: dir), config: config)
        defer { client.disconnect() }
        XCTAssertEqual(client.portMappingStatus, .idle)
        client.start()
        client.connect()
        pump()
        let server = try XCTUnwrap(factory.base.serverStreams.first)
        server.inject(TestFrames.loginSuccess())
        pump()

        XCTAssertEqual(client.portMappingStatus, .mapped(method: "NAT-PMP", externalPort: 41000))
        XCTAssertEqual(waitPorts(server).first, 2234)
        XCTAssertEqual(waitPorts(server).last, 41000)

        client.setPortMappingEnabled(false)
        XCTAssertEqual(client.portMappingStatus, .disabled)
        XCTAssertEqual(waitPorts(server).last, 2234)
        XCTAssertFalse(client.config.enablePortMapping)
    }

    func testConfigurationWithoutPortMappingKeyDefaultsToEnabled() throws {
        let legacy = Data(#"{"username":"tester","listenPort":2234}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(ClientConfiguration.self, from: legacy).enablePortMapping)
    }
}

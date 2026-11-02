import XCTest
@testable import PCLCore

final class AutomaticMultiplayerTests: XCTestCase {
    func testRoomCodeCarriesExactHostEntryPointsAndDoesNotExposeCredentialsInDescription() throws {
        let room = try PCLInvite.create(port: 25565)
        let link = try PCLRoomLink(invite: room, peers: ["tcp://[2001:db8::1]:32001", "udp://192.168.1.20:32001", "tcp://relay.example:11010"])
        let copied = try PCLRoomLink("在 PCL Mac版输入连接码【\(link.code)】，即可加入！")
        XCTAssertEqual(copied.invite, room); XCTAssertEqual(copied.peers, link.peers)
        XCTAssertFalse(String(describing: link).contains(room.networkSecret))
        XCTAssertFalse(String(reflecting: link).contains(link.code))
        XCTAssertThrowsError(try PCLRoomLink("PCLM1.corrupted"))
        XCTAssertThrowsError(try PCLRoomLink(String(repeating: "a", count: 8193)))
    }
    func testForgedLinkCannotInjectShellArgumentsAndRejectsVersionOrOversize() throws {
        func code(_ payload: [String: Any]) throws -> String {
            PCLRoomLink.prefix + (try JSONSerialization.data(withJSONObject: payload)).base64EncodedString()
        }
        let base: [String: Any] = ["version": 1, "invite": "P63DD-ABCDE-FGHJK-02000", "peers": ["--config-file=/tmp/room"]]
        XCTAssertThrowsError(try PCLRoomLink(code(base)))
        XCTAssertThrowsError(try PCLRoomLink(code(["version": 2, "invite": "P63DD-ABCDE-FGHJK-02000", "peers": ["tcp://host:11010"]])))
        XCTAssertThrowsError(try PCLRoomLink(code(["version": 1, "invite": "P63DD-ABCDE-FGHJK-02000", "peers": []])))
    }
    func testCatalogFiltersInactiveInvalidAndPrivateEntries() throws {
        let nodes: [[String: Any]] = [
            ["address": "tcp://relay.example:11010", "is_active": true, "allow_relay": true],
            ["address": "udp://relay.example:11010", "is_active": true, "allow_relay": true],
            ["address": "tcp://127.0.0.1:11010", "is_active": true, "allow_relay": true],
            ["address": "tcp://127.1:11010", "is_active": true, "allow_relay": true],
            ["address": "tcp://192.168.1.1:11010", "is_active": true, "allow_relay": true],
            ["address": "tcp://198.18.0.1:11010", "is_active": true, "allow_relay": true],
            ["address": "tcp://internal.local:11010", "is_active": true, "allow_relay": true],
            ["address": "file:///tmp/a", "is_active": true, "allow_relay": true],
            ["address": "tcp://inactive.example:11010", "is_active": false, "allow_relay": true],
            ["address": "tcp://unshared.example:11010", "is_active": true, "allow_relay": false]]
        let payload = try JSONSerialization.data(withJSONObject: ["success": true, "data": ["items": nodes]])
        XCTAssertEqual(try PCLLinkDiscovery.parseCatalog(payload), ["tcp://relay.example:11010", "udp://relay.example:11010"])
        XCTAssertThrowsError(try PCLLinkDiscovery.parseCatalog(Data("{}".utf8)))
        XCTAssertEqual(try PCLLinkDiscovery.parseCatalog(Data(#"[{"name":"published","url":"relay.example:11010"}]"#.utf8)), ["tcp://relay.example:11010"])
    }
    func testScaffoldingDiscoverySharesCEEntryPointsWithoutUserConfiguration() throws {
        let peers = try PCLLinkDiscovery.scaffoldingPeers(["tcp://relay.example:11010"])
        XCTAssertTrue(peers.contains("https://etnode.zkitefly.eu.org/node1"))
        XCTAssertTrue(peers.contains("tcp://public2.easytier.cn:54321"))
        XCTAssertEqual(try PCLLinkPeers.parse(peers.joined(separator: ","), maximum: 16), peers)
    }
    func testUnavailableCatalogFallsBackWithoutRequiringUserInputAndCancellationRemainsCancellation() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiscoveryFixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = PCLLinkDiscovery(cache: root.appendingPathComponent("nodes.json"))
        let peers = try await discovery.resolve(session: session)
        XCTAssertEqual(peers, PCLLinkDiscovery.fallbackPeers)
        let task = Task { try await discovery.resolve(session: session) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {}
    }
}

private final class DiscoveryFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}

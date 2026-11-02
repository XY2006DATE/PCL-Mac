import XCTest
import Darwin
@testable import PCLCore

final class MultiplayerTests: XCTestCase {
    func testInviteRoundTripNormalizesOriginalShareTextAndHidesCredentials() throws {
        let room = try PCLInvite("在 PCL 中输入【P63DD-ABCDE-FGHJK-02000】，加入房间！")
        XCTAssertEqual(room.port, 25565)
        XCTAssertEqual(room.networkName, "P63DD-ABCDE")
        XCTAssertEqual(room.networkSecret, "FGHJK")
        XCTAssertEqual(try PCLInvite("p63dd-abcde-fghjk-02000-extra"), room)
        XCTAssertEqual(try PCLInvite("P63DD-ABCDE-FGHJK-O2OOO"), room)
        XCTAssertFalse(String(describing: room).contains(room.networkSecret))
        XCTAssertFalse(String(reflecting: room).contains(room.code))
        let redacted = room.redacting("\u{1B}[31m\(room.code) secret=\(room.networkSecret)")
        XCTAssertFalse(redacted.contains(room.code)); XCTAssertFalse(redacted.contains(room.networkSecret))
        XCTAssertFalse(redacted.contains("\u{1B}"))
    }
    func testInviteValidationSeparatesUnsupportedProtocolsAndPublicNodes() throws {
        for invalid in ["", "P0000-ABCDE-FGHJK-02000", "P63DG-ABCDE-FGHJK-02000", "P63DD-ABCDE-FGHJK-03000", "P63DD-ABC E-FGHJK-02000", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try PCLInvite(invalid))
        }
        XCTAssertThrowsError(try PCLInvite("U/room")) { XCTAssertTrue($0.localizedDescription.contains("Scaffolding")) }
        let publicRoom = try PCLInvite("P63DD-ABCDE-FGHJK-02001")
        XCTAssertThrowsError(try publicRoom.requireCustomNode())
        for _ in 0..<30 {
            let created = try PCLInvite.create(port: 25565)
            XCTAssertEqual(created.code.count, 23); XCTAssertEqual(created.port, 25565)
            XCTAssertEqual(created.nodeID, 0); XCTAssertEqual(try PCLInvite(created.code), created)
        }
    }
    func testNodeValidationCannotInjectCredentialsArgumentsOrConfiguration() throws {
        XCTAssertEqual(try PCLLinkPeers.parse("tcp://localhost:11010，udp://[::1]:11010 tcp://localhost:11010"), ["tcp://localhost:11010", "udp://[::1]:11010"])
        for invalid in ["", "http://host:80", "tcp://host", "tcp://user:password@host:1234", "tcp://host:0", "tcp://host:65536", "tcp://host:11010/path", "tcp://host:11010?x=1", "tcp://host:11010#x", "--config-file=/tmp/a"] {
            XCTAssertThrowsError(try PCLLinkPeers.parse(invalid))
        }
        XCTAssertThrowsError(try PCLLinkPeers.parse((1...9).map { "tcp://host:\(10000 + $0)" }.joined(separator: ",")))
    }
    func testConfigMatchesV02AndKeepsSecretsOutOfProcessArguments() throws {
        let room = try PCLInvite("P63DD-ABCDE-FGHJK-02000")
        let host = try configuration(room, .host), guest = try configuration(room, .guest)
        XCTAssertTrue(host.toml.contains("ipv4 = \"10.114.114.114\""))
        XCTAssertTrue(host.toml.contains("tcp_whitelist = [\"25565\"]"))
        XCTAssertTrue(host.toml.contains("encryption_algorithm = \"chacha20\""))
        XCTAssertTrue(host.toml.contains("no_tun = true"))
        XCTAssertTrue(host.toml.contains("private_mode = true"))
        XCTAssertTrue(guest.toml.contains("hostname = \"Client-PCLMac\""))
        XCTAssertTrue(guest.toml.contains("dhcp = true"))
        XCTAssertTrue(guest.toml.contains("tcp_whitelist = [\"0\"]"))
        XCTAssertEqual(guest.toml.components(separatedBy: "[[port_forward]]").count - 1, 2)
        XCTAssertTrue(guest.toml.contains("bind_addr = \"127.0.0.1:31113\""))
        XCTAssertTrue(guest.toml.contains("dst_addr = \"10.114.114.114:25565\""))
        let args = host.coreArguments(configFile: URL(fileURLWithPath: "/tmp/room.toml"))
        XCTAssertFalse(args.joined().contains(room.networkSecret)); XCTAssertFalse(args.joined().contains(room.networkName))
        XCTAssertTrue(args.contains("127.0.0.1:31111")); XCTAssertTrue(args.contains("127.0.0.1/32"))
        XCTAssertThrowsError(try PCLLinkConfiguration(invite: room, role: .host, peers: host.peers, rpcPort: 31111, listenerPort: 31111, localPort: 31113))
    }
    func testPeerJSONUsesPinnedCoreSchemaAndDoesNotCountRelayAsPlayer() throws {
        let peers = try PCLLinkPeer.parse(Data(#"[{"hostname":"Server-PCLMac","ipv4":"10.114.114.114/24","cost":"Local","lat_ms":"-"},{"hostname":"Client-Windows","ipv4":"10.114.114.1","cost":"p2p","lat_ms":"12.50"},{"hostname":"Relay","ipv4":"","cost":"2","lat_ms":"NaN"}]"#.utf8))
        XCTAssertTrue(peers[0].isLocal); XCTAssertTrue(peers[0].isHost)
        XCTAssertEqual(peers.filter(\.isPlayer).count, 2)
        XCTAssertEqual(peers[1].connection, "直连"); XCTAssertEqual(peers[1].latencyMS, 12.5)
        XCTAssertNil(peers[2].latencyMS)
        XCTAssertThrowsError(try PCLLinkPeer.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try PCLLinkPeer.parse(Data("[{}]".utf8)))
    }
    func testReservedPortsAreDistinctAndReleased() throws {
        let reservation = LinkPortReservations(excluding: [25565])
        let a = try reservation.reserve(), b = try reservation.reserve()
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(a, 25565)
        reservation.release(); reservation.release()
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0); defer { Darwin.close(socket) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = a.bigEndian
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
    }
    func testPreCancelledProbeAndCommandDoNotHang() async throws {
        let probe = Task { try Task.checkCancellation(); try await LinkTCPProbe.connect(port: 1, timeout: 1) }
        probe.cancel()
        do { try await probe.value; XCTFail("Cancelled probe succeeded") } catch is CancellationError {}
        let command = Task { try await LinkCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 1) }
        command.cancel()
        do { _ = try await command.value; XCTFail("Cancelled command succeeded") } catch is CancellationError {}
    }
    func testCommandDeadlineStopsOnlyItsOwnChild() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await LinkCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.1); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    private func configuration(_ invite: PCLInvite, _ role: PCLLinkConfiguration.Role) throws -> PCLLinkConfiguration {
        try .init(invite: invite, role: role, peers: ["tcp://127.0.0.1:11010"], rpcPort: 31111, listenerPort: 31112, localPort: 31113)
    }
}

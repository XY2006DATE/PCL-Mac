import XCTest
@testable import PCLCore

/// Opt in with PCL_EASYTIER_TEST_DIR pointing to a verified release containing
/// easytier-core, easytier-cli and the compiled PCLLinkSupervisor. Uses loopback only.
final class MultiplayerIntegrationTests: XCTestCase {
    func testRealCoreSharedRelayHostDiscoveryAndTCPUDPForwarding() async throws {
        try await exercise(automatic: false)
    }
    func testAutomaticHostAndGuestConnectWithNoSharedServer() async throws {
        try await exercise(automatic: true)
    }
    func testAutomaticIPv6TCPUDPWithNoSharedServer() async throws {
        try await exercise(automatic: true, ipv6: true)
    }
    func testScaffoldingRoomControlDiscoveryProfilesAndGameTCPUDP() async throws {
        try await exercise(automatic: false, scaffolding: true)
    }
    private func exercise(automatic: Bool, ipv6: Bool = false, scaffolding: Bool = false) async throws {
        guard let path = ProcessInfo.processInfo.environment["PCL_EASYTIER_TEST_DIR"] else { throw XCTSkip("Set PCL_EASYTIER_TEST_DIR for real-core loopback integration") }
        let binaries = URL(fileURLWithPath: path)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PCL-link-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reservations = LinkPortReservations(excluding: [])
        let relayPort = try reservations.reserve(), relayRPC = try reservations.reserve(), gamePort = try reservations.reserve()
        let invite = try PCLInvite.create(port: gamePort)
        let scaffoldInvite = ScaffoldingInvite.create()
        let relayFile = root.appendingPathComponent("relay.toml")
        try Data("""
        instance_name = "test-relay"
        hostname = "ValidationRelay"
        listeners = ["tcp://127.0.0.1:\(relayPort)"]
        [network_identity]
        network_name = "validation-independent-network"
        network_secret = "validation-only"
        [flags]
        no_tun = true
        encryption_algorithm = "chacha20"
        private_mode = false
        """.utf8).write(to: relayFile)
        let relay = LinkProcess(), echo = LinkProcess()
        defer { relay.stop(); echo.stop(); reservations.release() }
        reservations.release()
        if !automatic {
            try relay.start(executable: binaries.appendingPathComponent("PCLLinkSupervisor"), arguments: [binaries.appendingPathComponent("easytier-core").path, "--config-file", relayFile.path, "--rpc-portal", "127.0.0.1:\(relayRPC)", "--disable-env-parsing", "--console-log-level", "error"])
        }
        // Same local application socket receives both TCP and UDP forwarded traffic.
        try echo.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", """
        import socket,threading,time
        port=\(gamePort)
        def serve(c):
          with c:
            while True:
              b=c.recv(65536)
              if not b: break
              c.sendall(b)
        def tcp():
          s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',port));s.listen()
          while True:
            c,_=s.accept();threading.Thread(target=serve,args=(c,),daemon=True).start()
        def udp():
          s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',port))
          while True:
            b,a=s.recvfrom(65536);s.sendto(b,a)
        threading.Thread(target=tcp,daemon=True).start();threading.Thread(target=udp,daemon=True).start();time.sleep(180)
        """])
        for _ in 0..<20 {
            if (try? await LinkTCPProbe.connect(port: gamePort, timeout: 0.2)) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let host = PCLMultiplayerSession(directory: root.appendingPathComponent("host"), supervisor: binaries.appendingPathComponent("PCLLinkSupervisor"))
        let guest = PCLMultiplayerSession(directory: root.appendingPathComponent("guest"), supervisor: binaries.appendingPathComponent("PCLLinkSupervisor"))
        let scaffoldHost = ScaffoldingSession(directory: root.appendingPathComponent("host"), supervisor: binaries.appendingPathComponent("PCLLinkSupervisor"))
        let scaffoldGuest = ScaffoldingSession(directory: root.appendingPathComponent("guest"), supervisor: binaries.appendingPathComponent("PCLLinkSupervisor"))
        let events = IntegrationEvents()
        let urls = EasyTierRuntime.Binaries(core: binaries.appendingPathComponent("easytier-core"), cli: binaries.appendingPathComponent("easytier-cli"))
        let nodes = ["tcp://127.0.0.1:\(relayPort)"]
        do {
            if scaffolding {
                // A real AES-GCM room discovered through an unrelated shared
                // node, followed by the CE-compatible binary control exchange.
                async let creating: Void = scaffoldHost.open(invite: scaffoldInvite, gamePort: gamePort, peers: nodes, latencyFirst: false, playerName: "Host", machineID: UUID().uuidString, binaries: urls) { events.receive($0) }
                async let joining: Void = scaffoldGuest.open(invite: scaffoldInvite, gamePort: nil, peers: nodes, latencyFirst: false, playerName: "Guest", machineID: UUID().uuidString, binaries: urls) { events.receive($0) }
                _ = try await (creating, joining)
                XCTAssertEqual(events.guest?.playerNames, ["Host", "Guest"])
                XCTAssertTrue(events.guest?.scaffolding == true)
            } else if automatic {
                // Nothing is listening at this entry point: the host must become
                // ready on its own and include direct addresses in its room code.
                try await host.open(invite: invite, role: .host, peers: nodes, latencyFirst: false, binaries: urls, automatic: true) { events.receive($0) }
                let hosted = try XCTUnwrap(events.host)
                XCTAssertTrue(hosted.automatic)
                let link = try PCLRoomLink(hosted.inviteCode)
                var guestNodes = link.peers
                if ipv6 {
                    let directPort = try XCTUnwrap(URLComponents(string: try XCTUnwrap(link.peers.first))?.port)
                    guestNodes = ["tcp://[::1]:\(directPort)", "udp://[::1]:\(directPort)"]
                }
                try await guest.open(invite: link.invite, role: .guest, peers: guestNodes, latencyFirst: false, binaries: urls, automatic: true) { events.receive($0) }
            } else {
                async let creating: Void = host.open(invite: invite, role: .host, peers: nodes, latencyFirst: false, binaries: urls) { events.receive($0) }
                async let joining: Void = guest.open(invite: invite, role: .guest, peers: nodes, latencyFirst: false, binaries: urls) { events.receive($0) }
                _ = try await (creating, joining)
            }
            let room = try XCTUnwrap(events.guest)
            XCTAssertTrue(room.peers.contains { $0.isHost && !$0.isLocal })
            XCTAssertGreaterThanOrEqual(room.playerCount, 2)
            let localPort = try XCTUnwrap(UInt16(room.localAddress.split(separator: ":").last ?? ""))
            let output = try await LinkCommand.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-c", """
            import socket
            payload=b'PCL-native-forward-validation'*4096
            with socket.create_connection(('127.0.0.1',\(localPort)),timeout=10) as s:
              s.sendall(payload);received=b''
              while len(received)<len(payload):
                chunk=s.recv(65536)
                assert chunk
                received+=chunk
              assert received==payload
            with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
              s.settimeout(10);s.sendto(b'PCL-UDP',('127.0.0.1',\(localPort)));assert s.recv(1024)==b'PCL-UDP'
            print('TCP/UDP payloads matched')
            """], timeout: 25)
            XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("payloads matched"))
            XCTAssertFalse(events.logs.joined().contains(invite.networkSecret))
            if scaffolding { XCTAssertFalse(events.logs.joined().contains(scaffoldInvite.networkSecret)) }
            // Configuration is private and removed when leaving; user files are outside this tree.
            let config = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("guest"), includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "room.toml" })
            let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
            await guest.stop(); await host.stop(); await scaffoldGuest.stop(); await scaffoldHost.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
            try await Task.sleep(nanoseconds: 400_000_000)
            do { try await LinkTCPProbe.connect(port: localPort, timeout: 0.3); XCTFail("Forward still listening after leave") } catch {}
        } catch {
            await host.stop(); await guest.stop(); await scaffoldGuest.stop(); await scaffoldHost.stop()
            // Events are already redacted by the production session.
            XCTFail("Real EasyTier integration failed: \(error.localizedDescription)\n\(events.logs.suffix(15).joined(separator: "\n"))")
            throw error
        }
    }
}

private final class IntegrationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var room: PCLRoomSnapshot?
    private var hosted: PCLRoomSnapshot?
    private var lines: [String] = []
    var guest: PCLRoomSnapshot? { lock.withLock { room } }
    var host: PCLRoomSnapshot? { lock.withLock { hosted } }
    var logs: [String] { lock.withLock { lines } }
    func receive(_ event: PCLRoomEvent) {
        lock.withLock {
            switch event {
            case .connected(let value): if value.isHost { hosted = value } else { room = value }
            case .output(let text): lines.append(text)
            default: break
            }
        }
    }
}

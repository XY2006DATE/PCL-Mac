import XCTest
@testable import PCLCore

/// Actual CE protocol code plus the flags in its supplied EasyTierEntity.cs.
/// Both endpoints run on this Mac; this does not replace Windows/Internet QA.
final class CETransportInteropTests: XCTestCase {
    func testMacGuestReachesActualCEHostWithKCPQUICAndP2POnly() async throws { try await exercise(ceHost: true) }
    func testActualCEGuestReachesMacHostWithKCPQUICAndP2POnly() async throws { try await exercise(ceHost: false) }
    private func exercise(ceHost: Bool) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let runtimePath = env["PCL_EASYTIER_TEST_DIR"], let dotnetPath = env["PCL_CE_DOTNET"], let dllPath = env["PCL_CE_INTEROP_DLL"] else { throw XCTSkip("Opt in with CE source harness and verified EasyTier runtime") }
        let runtime = URL(fileURLWithPath: runtimePath), dotnet = URL(fileURLWithPath: dotnetPath)
        let core = runtime.appendingPathComponent("easytier-core"), cli = runtime.appendingPathComponent("easytier-cli"), supervisor = runtime.appendingPathComponent("PCLLinkSupervisor")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PCL-CE-transport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = LinkPortReservations(excluding: [])
        let relayPort = try ports.reserve(), relayRPC = try ports.reserve(), ceRPC = try ports.reserve(), control = try ports.reserve(), game = try ports.reserve(), gameLocal = try ports.reserve()
        let invite = ScaffoldingInvite.create(), code = root.appendingPathComponent("invite.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: code.path, contents: Data(invite.code.utf8), attributes: [.posixPermissions: 0o600]))
        let node = "tcp://127.0.0.1:\(relayPort)"
        let relay = LinkProcess(), ce = LinkProcess(), echo = LinkProcess(), server = LinkProcess()
        defer { relay.stop(); ce.stop(); echo.stop(); server.stop(); ports.release() }
        let mac = ScaffoldingSession(directory: root.appendingPathComponent("mac"), supervisor: supervisor)
        let relayConfig = root.appendingPathComponent("relay.toml"), ceConfig = root.appendingPathComponent("ce.toml")
        try Data("""
        hostname="SourceInteropRelay"
        listeners=["\(node)"]
        [network_identity]
        network_name="independent-source-interop"
        network_secret="disposable"
        [flags]
        no_tun=true
        """.utf8).write(to: relayConfig)
        // Flags and host identity from CE EasyTierEntity._BuildProcessAsync.
        try Data("""
        hostname="\(ceHost ? "scaffolding-mc-server-\(control)" : UUID().uuidString)"
        \(ceHost ? "ipv4=\"10.114.51.41\"" : "dhcp=true")
        listeners=["tcp://0.0.0.0:0","udp://0.0.0.0:0"]
        tcp_whitelist=["\(ceHost ? String(game) : "0")","\(ceHost ? String(control) : "0")"]
        udp_whitelist=["\(ceHost ? String(game) : "0")","\(ceHost ? String(control) : "0")"]
        [network_identity]
        network_name="\(invite.networkName)"
        network_secret="\(invite.networkSecret)"
        [flags]
        no_tun=true
        multi_thread=true
        enable_kcp_proxy=true
        enable_quic_proxy=true
        encryption_algorithm="aes-gcm"
        compression="zstd"
        default_protocol="tcp"
        private_mode=true
        p2p_only=true
        [[peer]]
        uri="\(node)"
        """.utf8).write(to: ceConfig)
        ports.release()
        try relay.start(executable: supervisor, arguments: [core.path,"--config-file",relayConfig.path,"--rpc-portal","127.0.0.1:\(relayRPC)","--console-log-level","error","--file-log-level","off"])
        try echo.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", """
        import socket,threading,time
        def tcp():
          s=socket.socket();s.bind(('127.0.0.1',\(game)));s.listen()
          while True:
            c,_=s.accept()
            def serve(c):
              with c:
                while True:
                  b=c.recv(65536)
                  if not b:break
                  c.sendall(b)
            threading.Thread(target=serve,args=(c,),daemon=True).start()
        def udp():
          s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',\(game)))
          while True:
            b,a=s.recvfrom(65536);s.sendto(b,a)
        threading.Thread(target=tcp,daemon=True).start();threading.Thread(target=udp,daemon=True).start();time.sleep(140)
        """])
        for _ in 0..<30 {
            if (try? await LinkTCPProbe.connect(port: game, timeout: 0.1)) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if ceHost { try server.start(executable: dotnet, arguments: [dllPath,"server",String(control),String(game),code.path]) }
        try ce.start(executable: supervisor, arguments: [core.path,"--config-file",ceConfig.path,"--rpc-portal","127.0.0.1:\(ceRPC)","--disable-env-parsing","--console-log-level","error","--file-log-level","off"])
        let events = CEInteropEvents()
        do {
            try await mac.open(invite: invite, gamePort: ceHost ? nil : game, peers: [node], latencyFirst: false, playerName: ceHost ? "Mac Guest" : "Mac Host", machineID: UUID().uuidString, binaries: .init(core: core, cli: cli)) { events.receive($0) }
            let local: UInt16
            if ceHost {
                let room = try XCTUnwrap(events.latest)
                XCTAssertTrue(room.playerNames.contains("CE Host"))
                local = try XCTUnwrap(UInt16(room.localAddress.split(separator: ":").last ?? ""))
            } else {
                let deadline = ProcessInfo.processInfo.systemUptime + 60
                var host: PCLLinkPeer?
                while ProcessInfo.processInfo.systemUptime < deadline {
                    host = (try? await PCLMultiplayerSession.queryPeers(cli, port: ceRPC))?.first { !$0.isLocal && $0.hostname.hasPrefix("scaffolding-mc-server-") }
                    if host != nil { break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                let hostPort = try XCTUnwrap(host.flatMap { UInt16($0.hostname.split(separator: "-").last ?? "") })
                for (l,r) in [(control,hostPort),(gameLocal,game)] {
                    for proto in ["tcp","udp"] { _ = try await LinkCommand.run(cli,["-p","127.0.0.1:\(ceRPC)","port-forward","add",proto,"127.0.0.1:\(l)","10.114.51.41:\(r)"]) }
                }
                try await Task.sleep(nanoseconds: 5_000_000_000)
                let output = try await LinkCommand.run(dotnet,[dllPath,"client",String(control),String(game)],timeout:28)
                XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("CE_CLIENT_CONTROL_AND_HEARTBEATS_PASSED"))
                local = gameLocal
            }
            let output = try await LinkCommand.run(URL(fileURLWithPath: "/usr/bin/python3"),["-c","""
            import socket
            with socket.create_connection(('127.0.0.1',\(local)),timeout=10) as s:
              s.sendall(b'CE TCP');assert s.recv(64)==b'CE TCP'
            with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
              s.settimeout(10);s.sendto(b'CE UDP',('127.0.0.1',\(local)));assert s.recv(64)==b'CE UDP'
            print('CE TCP UDP passed')
            """],timeout:25)
            XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("CE TCP UDP passed"))
            await mac.stop()
        } catch {
            await mac.stop()
            XCTFail("CE source transport interop failed: \(error.localizedDescription)\n\(events.logs.suffix(8).joined(separator:"\n"))")
            throw error
        }
    }
}
private final class CEInteropEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var room: PCLRoomSnapshot?
    private var lines: [String] = []
    var latest: PCLRoomSnapshot? { lock.withLock { room } }
    var logs: [String] { lock.withLock { lines } }
    func receive(_ event: PCLRoomEvent) {
        lock.withLock {
            switch event { case .connected(let value): room=value
            case .output(let line), .progress(let line):lines.append(line)
            default:break }
        }
    }
}

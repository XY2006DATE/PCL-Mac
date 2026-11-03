import XCTest
@testable import PCLCore

final class LinkNodeIntegrationTests: XCTestCase {
    func testLateCERendezvousRecoversDespiteTwoUnrelatedHealthyRelays() async throws {
        guard let path = ProcessInfo.processInfo.environment["PCL_EASYTIER_TEST_DIR"] else { throw XCTSkip("Set PCL_EASYTIER_TEST_DIR for late rendezvous recovery") }
        let runtime = URL(fileURLWithPath: path), root = FileManager.default.temporaryDirectory.appendingPathComponent("PCL-late-CE-node-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = runtime.appendingPathComponent("easytier-cli"), core = runtime.appendingPathComponent("easytier-core"), supervisor = runtime.appendingPathComponent("PCLLinkSupervisor")
        let ports = LinkPortReservations(excluding: [])
        let nodes = try (0..<3).map { _ in "tcp://127.0.0.1:\(try ports.reserve())" }
        let relayRPC = try (0..<3).map { _ in try ports.reserve() }, rpc = try ports.reserve()
        let relays = (0..<3).map { _ in LinkProcess() }, client = LinkProcess()
        defer { relays.forEach { $0.stop() }; client.stop(); ports.release() }
        var files: [URL] = []
        for i in 0..<3 {
            let file = root.appendingPathComponent("relay-\(i).toml")
            try Data("hostname=\"Relay-\(i)\"\nlisteners=[\"\(nodes[i])\"]\n[network_identity]\nnetwork_name=\"independent-\(i)\"\nnetwork_secret=\"disposable\"\n[flags]\nno_tun=true\n".utf8).write(to: file)
            files.append(file)
        }
        let file = root.appendingPathComponent("client.toml")
        try Data(("listeners=[]\n[network_identity]\nnetwork_name=\"late-ce-recovery\"\nnetwork_secret=\"disposable\"\n[flags]\nno_tun=true\n" + nodes.map { "[[peer]]\nuri=\"\($0)\"\n" }.joined()).utf8).write(to: file)
        ports.release()
        func startRelay(_ i: Int) throws {
            try relays[i].start(executable: supervisor, arguments: [core.path,"--config-file",files[i].path,"--rpc-portal","127.0.0.1:\(relayRPC[i])","--console-log-level","error","--file-log-level","off"])
        }
        try startRelay(0); try startRelay(1)
        try client.start(executable: supervisor, arguments: [core.path,"--config-file",file.path,"--rpc-portal","127.0.0.1:\(rpc)","--console-log-level","error","--file-log-level","off"])
        let keeper = Task { await LinkNodeMaintenance.run(cli: cli, rpc: rpc, peers: nodes, rendezvousPeers: [nodes[2]]) { _ in } }
        defer { keeper.cancel() }
        func query() async throws -> [LinkConnector] { try await LinkConnector.parse(LinkCommand.run(cli,["-p","127.0.0.1:\(rpc)","-o","json","connector","list"])) }
        var selected: [LinkConnector] = []
        let initial = ProcessInfo.processInfo.systemUptime + 22
        while ProcessInfo.processInfo.systemUptime < initial {
            selected = (try? await query()) ?? []
            if selected.filter(\.connected).count == 2 && !selected.contains(where: { $0.url.url == nodes[2] }) { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(selected.filter(\.connected).count, 2)
        XCTAssertFalse(selected.contains { $0.url.url == nodes[2] })
        try startRelay(2)
        let recovery = ProcessInfo.processInfo.systemUptime + 42
        while ProcessInfo.processInfo.systemUptime < recovery {
            selected = (try? await query()) ?? []
            if selected.contains(where: { $0.url.url == nodes[2] && $0.connected }) { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(selected.contains { $0.url.url == nodes[2] && $0.connected }, "CE rendezvous was never reprobed after two unrelated relays connected")
        XCTAssertEqual(selected.filter(\.connected).count, 3)
        keeper.cancel(); await keeper.value
    }
    func testRealCoreKeepsHandshakenRelayAndRemovesDeadConnectorWithoutFileLogs() async throws {
        guard let path = ProcessInfo.processInfo.environment["PCL_EASYTIER_TEST_DIR"] else { throw XCTSkip("Set PCL_EASYTIER_TEST_DIR for real connector maintenance") }
        let runtime = URL(fileURLWithPath: path)
        let cli = runtime.appendingPathComponent("easytier-cli")
        let core = runtime.appendingPathComponent("easytier-core")
        let supervisor = runtime.appendingPathComponent("PCLLinkSupervisor")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PCL-node-maintenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ports = LinkPortReservations(excluding: [])
        let relayPort = try ports.reserve(), relayRPC = try ports.reserve(), clientRPC = try ports.reserve(), deadPort = try ports.reserve()
        let live = "tcp://127.0.0.1:\(relayPort)", dead = "tcp://127.0.0.1:\(deadPort)"
        let common = """
        [network_identity]
        network_name = "connector-maintenance-test"
        network_secret = "disposable"
        [flags]
        no_tun = true
        """
        let relayConfig = root.appendingPathComponent("relay.toml"), clientConfig = root.appendingPathComponent("client.toml")
        try Data(("hostname=\"ValidationRelay\"\nlisteners=[\"\(live)\"]\n" + common).utf8).write(to: relayConfig)
        try Data(("hostname=\"MaintenanceClient\"\nlisteners=[]\n" + common + "\n[[peer]]\nuri=\"\(live)\"\n[[peer]]\nuri=\"\(dead)\"\n").utf8).write(to: clientConfig)
        let relay = LinkProcess(), client = LinkProcess()
        defer { relay.stop(); client.stop(); ports.release() }
        ports.release()
        try relay.start(executable: supervisor, arguments: [core.path, "--config-file", relayConfig.path, "--rpc-portal", "127.0.0.1:\(relayRPC)", "--disable-env-parsing"] + LinkRuntimeOptions.logging, workingDirectory: root)
        try client.start(executable: supervisor, arguments: [core.path, "--config-file", clientConfig.path, "--rpc-portal", "127.0.0.1:\(clientRPC)", "--disable-env-parsing"] + LinkRuntimeOptions.logging, workingDirectory: root)
        let keeper = Task { await LinkNodeMaintenance.run(cli: cli, rpc: clientRPC, peers: [live, dead]) { _ in } }
        defer { keeper.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + 23
        var selected: [LinkConnector] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? await LinkCommand.run(cli, ["-p", "127.0.0.1:\(clientRPC)", "-o", "json", "connector", "list"]), let list = try? LinkConnector.parse(data) {
                selected = list
                if list.contains(where: { $0.url.url == live && $0.connected }) && !list.contains(where: { $0.url.url == dead }) { break }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(selected.contains { $0.url.url == live && $0.connected }, "Healthy relay was removed or never handshook")
        XCTAssertFalse(selected.contains { $0.url.url == dead }, "Dead connector remains in fast retry loop")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        XCTAssertFalse(files.contains { $0.pathExtension == "log" || $0.lastPathComponent.contains("easytier.log") })
        keeper.cancel(); await keeper.value
        client.stop(); relay.stop()
        for _ in 0..<40 {
            if !client.isRunning && !relay.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(client.isRunning); XCTAssertFalse(relay.isRunning)
    }
}

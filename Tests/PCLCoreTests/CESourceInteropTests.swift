import XCTest
@testable import PCLCore

/// Builds the supplied CE protocol sources unchanged; these are not Swift or
/// Python reimplementations of the other endpoint. Opt-in paths keep .NET out
/// of the app and normal test environment.
final class CESourceInteropTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        guard let host = ProcessInfo.processInfo.environment["PCL_CE_DOTNET"], let dll = ProcessInfo.processInfo.environment["PCL_CE_INTEROP_DLL"] else { throw XCTSkip("Set PCL_CE_DOTNET and PCL_CE_INTEROP_DLL for CE source interoperability") }
        return (URL(fileURLWithPath: host), URL(fileURLWithPath: dll))
    }
    func testActualCEClientCanHandshakeAndKeepHeartbeatWithMacHost() async throws {
        let (dotnet,dll) = try fixture()
        let ports = LinkPortReservations(excluding: []); let port = try ports.reserve(); ports.release()
        let host = ScaffoldingServer(gamePort: 25565, host: .init(name: "Mac Host", machine_id: "mac-source-host", vendor: "test", kind: "HOST"))
        try await host.start(port: port); defer { host.stop() }
        let output = try await LinkCommand.run(dotnet, [dll.path,"client",String(port),"25565"], timeout: 28)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("CE_CLIENT_CONTROL_AND_HEARTBEATS_PASSED"))
    }
    func testMacClientCanHandshakeWithActualCEServerAndCEParsesMacLobbyIdentity() async throws {
        let (dotnet,dll) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PCL-CE-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let invite = ScaffoldingInvite.create(), code = root.appendingPathComponent("invite.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: code.path, contents: Data(invite.code.utf8), attributes: [.posixPermissions: 0o600]))
        let parsed = try await LinkCommand.run(dotnet, [dll.path,"parse",code.path])
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed) as? [String:String])
        XCTAssertEqual(identity["NetworkName"], invite.networkName); XCTAssertEqual(identity["NetworkSecret"], invite.networkSecret)
        let ports = LinkPortReservations(excluding: []); let port = try ports.reserve(); ports.release()
        let server = LinkProcess(); defer { server.stop() }
        try server.start(executable: dotnet, arguments: [dll.path,"server",String(port),"25565",code.path])
        for _ in 0..<40 {
            if (try? await LinkTCPProbe.connect(port: port, timeout: 0.1)) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let game = try await ScaffoldingRPC.call(port: port, type: "c:server_port")
        XCTAssertEqual(game, Data([0x63,0xdd]))
        let profile = ScaffoldingProfile(name: "Mac Guest", machine_id: "mac-guest", vendor: "test", kind: nil)
        _ = try await ScaffoldingRPC.call(port: port, type: "c:player_ping", body: JSONEncoder().encode(profile))
        let list = try await ScaffoldingRPC.call(port: port, type: "c:player_profiles_list")
        let players = try JSONDecoder().decode([ScaffoldingProfile].self, from: list)
        XCTAssertTrue(players.contains { $0.name == "CE Host" && $0.kind == "HOST" })
        XCTAssertTrue(players.contains { $0.machine_id == "mac-guest" })
    }
}

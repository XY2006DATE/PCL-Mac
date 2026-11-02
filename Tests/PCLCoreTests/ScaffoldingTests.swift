import XCTest
@testable import PCLCore

final class ScaffoldingTests: XCTestCase {
    func testCodesHaveOriginalLengthAlphabetChecksumAndCredentials() throws {
        let zero = try ScaffoldingInvite("U/0000-0000-0000-0000")
        XCTAssertEqual(zero.networkName, "scaffolding-mc-0000-0000"); XCTAssertEqual(zero.networkSecret, "0000-0000")
        // Independent little-endian base-34 reference: integer 1234567888.
        XCTAssertEqual(try ScaffoldingInvite("U/7ARU-5T00-0000-0000").networkName, "scaffolding-mc-7ARU-5T00")
        for _ in 0..<100 {
            let room = ScaffoldingInvite.create()
            XCTAssertEqual(room.code.count, 21); XCTAssertEqual(try ScaffoldingInvite(room.code).networkName, room.networkName)
            XCTAssertFalse(String(describing: room).contains(room.networkSecret))
            XCTAssertFalse(room.redacting(room.code + " " + room.networkSecret).contains(room.networkSecret))
        }
        XCTAssertEqual(try ScaffoldingInvite("分享【U/0000-0000-0000-0000】").code, zero.code)
        XCTAssertThrowsError(try ScaffoldingInvite("U/1000-0000-0000-0000"))
        XCTAssertThrowsError(try ScaffoldingInvite("U/00000-000-0000-0000"))
    }
    func testFramingMatchesCERawBytesHandlesFragmentsAndBoundsBodies() throws {
        let packet = ScaffoldingFrame.request("c:server_port")
        XCTAssertEqual(packet.map { String(format: "%02x", $0) }.joined(), "0d633a7365727665725f706f727400000000")
        var pending = Data()
        for byte in packet.dropLast() { pending.append(byte); XCTAssertNil(try ScaffoldingFrame.takeRequest(&pending)) }
        pending.append(packet.last!)
        let result = try XCTUnwrap(ScaffoldingFrame.takeRequest(&pending))
        XCTAssertEqual(result.0, "c:server_port"); XCTAssertTrue(result.1.isEmpty); XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(ScaffoldingFrame.response(body: Data([0x63, 0xdd])), Data([0, 0, 0, 0, 2, 0x63, 0xdd]))
        var invalid = Data([1, 65, 0xff, 0xff, 0xff, 0xff]); XCTAssertThrowsError(try ScaffoldingFrame.takeRequest(&invalid))
    }
    func testControlServerExchangesPortPingCapabilitiesAndProfiles() async throws {
        let ports = LinkPortReservations(excluding: []); let port = try ports.reserve(); ports.release()
        let host = ScaffoldingProfile(name: "Host", machine_id: "host-test", vendor: "test", kind: "HOST")
        let server = ScaffoldingServer(gamePort: 25565, host: host)
        try await server.start(port: port); defer { server.stop() }
        let receivedPort = try await ScaffoldingRPC.call(port: port, type: "c:server_port")
        XCTAssertEqual(receivedPort, Data([0x63, 0xdd]))
        let ping = Data([0, 3, 255, 128])
        let echo = try await ScaffoldingRPC.call(port: port, type: "c:ping", body: ping); XCTAssertEqual(echo, ping)
        let protocols = try await ScaffoldingRPC.call(port: port, type: "c:protocols")
        XCTAssertTrue(String(decoding: protocols, as: UTF8.self).contains("c:player_ping"))
        let guest = ScaffoldingProfile(name: "Guest", machine_id: "guest-test", vendor: "PCL CE fixture", kind: nil)
        let registered = try await ScaffoldingRPC.call(port: port, type: "c:player_ping", body: JSONEncoder().encode(guest)); XCTAssertTrue(registered.isEmpty)
        let bytes = try await ScaffoldingRPC.call(port: port, type: "c:player_profiles_list")
        let profiles = try JSONDecoder().decode([ScaffoldingProfile].self, from: bytes)
        XCTAssertEqual(profiles.map(\.name), ["Host", "Guest"]); XCTAssertEqual(profiles.map(\.kind), ["HOST", "GUEST"])
        do { _ = try await ScaffoldingRPC.call(port: port, type: "unsupported"); XCTFail("Unsupported request accepted") } catch {}
    }
    func testScaffoldingConfigUsesCEIdentityCipherAndOnlyRequiredPorts() throws {
        let invite = ScaffoldingInvite.create()
        let text = ScaffoldingSession.configuration(invite: invite, gamePort: 25565, control: 31001, listener: 31002, peers: ["tcp://relay.example:11010"], latencyFirst: false, machineID: UUID().uuidString)
        XCTAssertTrue(text.contains("10.114.51.41")); XCTAssertTrue(text.contains("aes-gcm"))
        XCTAssertTrue(text.contains("scaffolding-mc-server-31001")); XCTAssertTrue(text.contains("[\"25565\", \"31001\"]"))
        XCTAssertTrue(text.contains("uri = \"tcp://relay.example:11010\""))
        XCTAssertTrue(text.contains("no_tun = true")); XCTAssertTrue(text.contains("relay_network_whitelist = \"\""))
    }
    func testCancelledRPCDoesNotHang() async throws {
        let operation = Task { try await ScaffoldingRPC.call(port: 1, type: "c:ping", timeout: 30) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Ignored cancellation") } catch is CancellationError {}
    }
    func testPersistentCEStyleClientKeepsItsConnectionAcrossHeartbeats() async throws {
        let ports = LinkPortReservations(excluding: []); let port = try ports.reserve(); ports.release()
        let server = ScaffoldingServer(gamePort: 25565, host: .init(name: "Host", machine_id: "fixture", vendor: "test", kind: "HOST"))
        try await server.start(port: port); defer { server.stop() }
        let output = try await LinkCommand.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-c", """
        import socket,struct,time
        def read(s,n):
          data=b''
          while len(data)<n:
            chunk=s.recv(n-len(data))
            assert chunk
            data+=chunk
          return data
        with socket.create_connection(('127.0.0.1',\(port)),timeout=3) as s:
          for i in range(5):
            if i: time.sleep(4)
            kind=b'c:ping';body=bytes([i,255])
            packet=bytes([len(kind)])+kind+struct.pack('>I',len(body))+body
            s.sendall(packet[:3]);s.sendall(packet[3:])
            status,size=struct.unpack('>BI',read(s,5))
            assert status==0 and read(s,size)==body
        print('persistent reference client passed')
        """], timeout: 23)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("reference client passed"))
    }
}

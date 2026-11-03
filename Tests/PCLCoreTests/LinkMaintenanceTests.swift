import XCTest
import Darwin
@testable import PCLCore

final class LinkMaintenanceTests: XCTestCase {
    private let a = "tcp://one.example:11010", b = "tcp://two.example:11010", dead = "https://discovery.example/node"
    private func status(_ url: String, _ state: Int = 0) -> LinkConnector { .init(url: .init(url: url), status: state) }
    func testPinnedConnectorSchemaDistinguishesConnectedFromDisconnected() throws {
        let data = Data(#"[{"url":{"url":"tcp://live.example:11010"},"status":0},{"url":{"url":"tcp://dead.example:11010"},"status":1},{"url":{"url":"tcp://probing.example:11010"},"status":2}]"#.utf8)
        XCTAssertEqual(try LinkConnector.parse(data).map(\.connected), [true, false, false])
        XCTAssertThrowsError(try LinkConnector.parse(Data(#"[{"url":{"url":"bad"},"status":3}]"#.utf8)))
    }
    func testDeadEntryRemovedAfterResolutionGraceAndHealthyEntriesRemain() {
        var policy = LinkNodePolicy(peers: [a,b,dead], now: 0)
        let peers = [status(a),status(b),status(dead,2)]
        XCTAssertEqual(policy.actions(status: peers, now: 24), [])
        XCTAssertEqual(policy.actions(status: peers, now: 25), [.remove(dead)])
        policy.applied(.remove(dead), now: 25)
        XCTAssertEqual(policy.actions(status: [status(a),status(b)], now: 3600), [])
    }
    func testRecoveryBackoffGrowsAndCapsAndConnectionLossProbesAgain() {
        var policy = LinkNodePolicy(peers: [a], now: 0)
        var now: TimeInterval = 8
        for delay in [30.0,60,120,240,300,300] {
            XCTAssertEqual(policy.actions(status: [status(a,1)], now: now), [.remove(a)])
            policy.applied(.remove(a), now: now)
            XCTAssertEqual(policy.actions(status: [], now: now + delay - 0.1), [])
            now += delay
            XCTAssertEqual(policy.actions(status: [], now: now), [.add(a)])
            policy.applied(.add(a), now: now)
            XCTAssertEqual(policy.actions(status: [status(a,2)], now: now + 7), [])
            now += 8
        }
    }
    func testUnreachableBackupsAreRetriedWhenHealthyConnectionIsLost() {
        var policy = LinkNodePolicy(peers: [a,b,dead], now: 0)
        XCTAssertEqual(policy.actions(status: [status(a),status(b)], now: 25), [.remove(dead)])
        policy.applied(.remove(dead), now: 25)
        XCTAssertEqual(policy.actions(status: [status(a),status(b)], now: 56), [])
        let actions = policy.actions(status: [status(a),status(b,1)], now: 57)
        XCTAssertTrue(actions.contains(.add(dead)))
        XCTAssertFalse(actions.contains(.remove(a)))
    }
    func testCESharedRendezvousIsReprobedEvenWithTwoUnrelatedHealthyRelays() {
        var policy = LinkNodePolicy(peers: [a,b,dead], now: 0, rendezvousPeers: [dead])
        XCTAssertEqual(policy.actions(status: [status(a),status(b)], now: 25), [.remove(dead)])
        policy.applied(.remove(dead), now: 25)
        XCTAssertEqual(policy.actions(status: [status(a),status(b)], now: 54), [])
        XCTAssertEqual(policy.actions(status: [status(a),status(b)], now: 55), [.add(dead)])
        policy.applied(.add(dead), now: 55)
        XCTAssertEqual(policy.actions(status: [status(a),status(b),status(dead)], now: 60), [])
        XCTAssertEqual(policy.actions(status: [status(a),status(b),status(dead)], now: 300), [])
    }
    func testUnconfiguredCERendezvousNeverAddsPublicNodesToCustomOnlyRoom() {
        var policy = LinkNodePolicy(peers: [a,b], now: 0, rendezvousPeers: [dead])
        XCTAssertEqual(policy.actions(status: [status(a),status(b)], now: 300), [])
    }
    func testRetryDoesNotReAddBeforeRemovalActuallySucceeded() {
        var policy = LinkNodePolicy(peers: [a], now: 0)
        XCTAssertEqual(policy.actions(status: [], now: 10), [.remove(a)])
        XCTAssertEqual(policy.actions(status: [], now: 45), [.remove(a)])
    }
    func testRepeatedWarningsAreMergedBeforeDeliveryAndUniqueBurstIsBounded() {
        var limiter = LinkLogLimiter()
        XCTAssertNotNil(limiter.accept("2026-11-03T03:29:41+08:00 WARN reconn_tasks done, handshake timeout after 1.99s", now: 0))
        for i in 1...10000 {
            XCTAssertNil(limiter.accept("2026-11-03T03:29:42+08:00 WARN reconn_tasks done, handshake timeout after \(i)s", now: 1))
        }
        let summary = limiter.accept("new diagnostic", now: 2)
        XCTAssertTrue(summary?.contains("合并 10000 条") == true)
        var count = 0
        for i in 0..<1000 { if limiter.accept("unique diagnostic \(i)", now: 4) != nil { count += 1 } }
        XCTAssertEqual(count, 4)
        XCTAssertNotNil(limiter.accept("reconn_tasks done, still unavailable", now: 31))
    }
    func testLogTailHasHardByteAndCountLimitsEvenWithLongUnicode() {
        var buffer = LinkLogBuffer()
        for i in 0..<5000 { buffer.append("\(i):" + String(repeating: "联机", count: 2000)) }
        XCTAssertLessThanOrEqual(buffer.byteCount, 64 * 1024)
        XCTAssertLessThanOrEqual(buffer.lines.joined(separator: "\n").utf8.count, 64 * 1024)
        XCTAssertLessThanOrEqual(buffer.lines.count, 200)
        XCTAssertTrue(buffer.lines.last?.hasPrefix("4999:") == true)
        buffer = LinkLogBuffer()
        for i in 0..<1000 { buffer.append("event \(i)") }
        XCTAssertEqual(buffer.lines.count, 200); XCTAssertEqual(buffer.lines.first, "event 800")
    }
    func testOnlyAbandonedOwnedSessionMetadataIsCleaned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PCL-storage-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try LinkSessionStorage.create(in: root)
        let unknown = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let other = root.appendingPathComponent("user-folder")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let abandoned = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        // Acquire a known finished PID rather than guessing a nonexistent one.
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        try Data("{\"pid\":\(child.processIdentifier)}".utf8).write(to: abandoned.appendingPathComponent("owner.json"))
        _ = try LinkSessionStorage.create(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        for url in [active, unknown, other] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: active.appendingPathComponent("owner.json").path)[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }
}

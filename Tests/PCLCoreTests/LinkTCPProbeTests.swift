import XCTest
import Darwin
@testable import PCLCore

final class LinkTCPProbeTests: XCTestCase {
    func testClosedGamePortIsExplainedImmediatelyRatherThanMisreportedAsTimeout() async throws {
        let socket = try BoundProbeSocket(); defer { socket.stop() }
        socket.stop()
        let start = ProcessInfo.processInfo.systemUptime
        do { try await LinkTCPProbe.requireGame(port: socket.port, timeout: 5); XCTFail("Unopened game accepted") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Minecraft 游戏端口 \(socket.port)"))
            XCTAssertTrue(error.localizedDescription.contains("对局域网开放"))
            XCTAssertFalse(error.localizedDescription.contains("超时"))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }
    func testRawRefusedConnectionPreservesItsReasonAndPort() async throws {
        let socket = try BoundProbeSocket(); defer { socket.stop() }
        socket.stop()
        do { try await LinkTCPProbe.connect(port: socket.port); XCTFail("Expected refusal") }
        catch { XCTAssertEqual(error as? LinkTCPProbe.Failure, .notListening(socket.port)) }
    }
    func testAListeningGamePortSucceeds() async throws {
        let socket = try BoundProbeSocket(); defer { socket.stop() }
        XCTAssertTrue(socket.listen())
        try await LinkTCPProbe.requireGame(port: socket.port)
    }
    func testForwardRetriesUntilDelayedListenerIsActuallyReady() async throws {
        let socket = try BoundProbeSocket(); defer { socket.stop() }
        let delayed = DispatchWorkItem { _ = socket.listen() }
        defer { delayed.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.35, execute: delayed)
        let start = ProcessInfo.processInfo.systemUptime
        try await LinkTCPProbe.waitForForward(port: socket.port, timeout: 2)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.3)
    }
    func testForwardTimeoutNamesTheForwardInsteadOfTellingUserToStartGame() async throws {
        let socket = try BoundProbeSocket(); defer { socket.stop() }
        do { try await LinkTCPProbe.waitForForward(port: socket.port, timeout: 0.35); XCTFail("Expected forward timeout") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("联机转发端口 \(socket.port)"))
            XCTAssertTrue(error.localizedDescription.contains("重新加入"))
            XCTAssertFalse(error.localizedDescription.contains("启动游戏"))
        }
    }
    func testForwardRetryCancelsPromptly() async throws {
        let socket = try BoundProbeSocket(); defer { socket.stop() }
        let operation = Task { try await LinkTCPProbe.waitForForward(port: socket.port, timeout: 30) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = ProcessInfo.processInfo.systemUptime; operation.cancel()
        do { try await operation.value; XCTFail("Cancellation ignored") } catch is CancellationError {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }
}

/// Bound, non-listening sockets silently drop SYNs on Darwin. Closing models a
/// refused game port; delayed listen models a forward that is still starting.
private final class BoundProbeSocket: @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var descriptor: Int32
    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard bound == 0, named == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        descriptor = fd; port = UInt16(bigEndian: address.sin_port)
    }
    func listen() -> Bool { lock.withLock { descriptor >= 0 && Darwin.listen(descriptor, 8) == 0 } }
    func stop() { lock.withLock { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } } }
    deinit { stop() }
}

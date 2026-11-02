import XCTest
@testable import PCLCore

final class DownloadPolicyTests: XCTestCase {
    func testOriginalSpeedSliderBoundaries() {
        XCTAssertEqual(DownloadPolicy.speedBytes(slider: 0), 104858)
        XCTAssertEqual(DownloadPolicy.speedBytes(slider: 14), 1572864)
        XCTAssertEqual(DownloadPolicy.speedBytes(slider: 15), 2097152)
        XCTAssertEqual(DownloadPolicy.speedBytes(slider: 31), 10485760)
        XCTAssertEqual(DownloadPolicy.speedBytes(slider: 32), 11534336)
        XCTAssertEqual(DownloadPolicy.speedBytes(slider: 41), 20971520)
        XCTAssertEqual(DownloadPolicy.speedBytes(slider: 42), 0)
    }
    func testRateBudgetIsSharedAndChangingLimitResetsTimeline() {
        let budget = DownloadPolicy()
        budget.configure(maximumConcurrent: 2, bytesPerSecond: 100)
        XCTAssertEqual(budget.reserve(bytes: 50, now: 100), 100.5)
        XCTAssertEqual(budget.reserve(bytes: 50, now: 100), 101)
        XCTAssertEqual(budget.reserve(bytes: 100, now: 102), 103)
        budget.configure(maximumConcurrent: 1, bytesPerSecond: 0)
        XCTAssertEqual(budget.reserve(bytes: 100, now: 102), 102)
    }
    func testCancellationOfQueuedTransferDoesNotConsumeCapacity() async throws {
        let budget = DownloadPolicy()
        budget.configure(maximumConcurrent: 1, bytesPerSecond: 0)
        try await budget.acquire()
        let waiting = Task { try await budget.acquire() }
        try await Task.sleep(nanoseconds: 30_000_000)
        waiting.cancel()
        do { try await waiting.value; XCTFail("Queued operation must cancel") } catch is CancellationError {}
        budget.release()
        try await budget.acquire()
        budget.release()
    }
    func testCancellationInterruptsRateWait() async throws {
        let waiting = Task { try await DownloadPolicy.wait(until: ProcessInfo.processInfo.systemUptime + 60) }
        waiting.cancel()
        do { try await waiting.value; XCTFail("Rate wait must cancel") } catch is CancellationError {}
    }
}

final class DownloadPolicyTransportTests: XCTestCase {
    func testTransportActuallySharesConcurrencyAndRateLimit() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BudgetFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); DownloadPolicy.shared.configure(maximumConcurrent: 64, bytesPerSecond: 0) }
        DownloadPolicy.shared.configure(maximumConcurrent: 2, bytesPerSecond: 128 * 1024)
        BudgetFixtureProtocol.reset()
        let start = ProcessInfo.processInfo.systemUptime
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<4 {
                group.addTask {
                    let (file, _) = try await PCLHTTPS.download(for: URLRequest(url: URL(string: "https://budget.invalid/\(i)")!), session: session)
                    defer { try? FileManager.default.removeItem(at: file) }
                    XCTAssertEqual(try Data(contentsOf: file).count, 32 * 1024)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertLessThanOrEqual(BudgetFixtureProtocol.peakCount, 2)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.85)
    }
}

private final class BudgetFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var active = 0
    static var peak = 0
    var ended = false
    static var peakCount: Int { lock.withLock { peak } }
    static func reset() { lock.withLock { active = 0; peak = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "budget.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.active += 1; Self.peak = max(Self.peak, Self.active) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            guard !Self.lock.withLock({ ended }) else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": "32768"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 32768))
            end()
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    func end() { Self.lock.withLock { if !ended { ended = true; Self.active -= 1 } } }
    override func stopLoading() { end() }
}

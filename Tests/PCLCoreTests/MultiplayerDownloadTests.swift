import XCTest
@testable import PCLCore

final class MultiplayerDownloadTests: XCTestCase {
    func testOfficialRangeWorksThroughApplicationDownloadTransport() async throws {
        guard let path = ProcessInfo.processInfo.environment["PCL_EASYTIER_TEST_ZIP"] else { throw XCTSkip("Set PCL_EASYTIER_TEST_ZIP to opt in to official transport check") }
        let zip = try ModpackZIPArchive(url: URL(fileURLWithPath: path))
        let architecture: EasyTierRuntime.Architecture = zip.entries.contains { $0.path.hasPrefix("easytier-macos-x86_64/") } ? .x86_64 : .arm64
        let asset = EasyTierRuntime.asset(for: architecture)
        var request = URLRequest(url: asset.url); request.timeoutInterval = 120
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (file, response) = try await PCLHTTPS.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 0-65535/\(asset.size)")
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: URL(fileURLWithPath: path)).prefix(65536))
    }
    func testPinnedOfficialArchiveInstallsAndTamperedCacheIsRejected() throws {
        guard let path = ProcessInfo.processInfo.environment["PCL_EASYTIER_TEST_ZIP"] else { throw XCTSkip("Set PCL_EASYTIER_TEST_ZIP to a verified official release ZIP") }
        let zip = try ModpackZIPArchive(url: URL(fileURLWithPath: path))
        let architecture: EasyTierRuntime.Architecture = zip.entries.contains { $0.path.hasPrefix("easytier-macos-x86_64/") } ? .x86_64 : .arm64
        let asset = EasyTierRuntime.asset(for: architecture)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PCL-runtime-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("runtime")
        let result = try EasyTierRuntime.install(zip: URL(fileURLWithPath: path), asset: asset, target: target)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)), ["easytier-core", "easytier-cli", "receipt.json"])
        XCTAssertEqual(try EasyTierRuntime.cached(at: target, archive: asset.sha256).core, result.core)
        let original = try Data(contentsOf: result.cli)
        try Data("modified".utf8).write(to: result.cli)
        XCTAssertThrowsError(try EasyTierRuntime.cached(at: target, archive: asset.sha256))
        // Reinstall repairs an existing corrupted cache atomically.
        _ = try EasyTierRuntime.install(zip: URL(fileURLWithPath: path), asset: asset, target: target)
        XCTAssertEqual(try Data(contentsOf: result.cli), original)
        let corruptZip = root.appendingPathComponent("bad.zip")
        try Data("unverified archive".utf8).write(to: corruptZip)
        XCTAssertThrowsError(try EasyTierRuntime.install(zip: corruptZip, asset: asset, target: target))
        XCTAssertEqual(try Data(contentsOf: result.cli), original)
    }
    func testRangeDownloadReusesCompletedChunksAndValidatesResponse() async throws {
        let session = fixtureSession(); defer { session.invalidateAndCancel() }
        let payload = Data((0..<600_000).map { UInt8($0 % 251) })
        RangeFixture.set(payload: payload, malformed: false, failSecondOnce: true)
        let asset = EasyTierRuntime.Asset(url: URL(string: "https://runtime.invalid/core.zip")!, sha256: "fixture", size: payload.count)
        let file = try await EasyTierRuntime.download(asset, session: session, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), payload)
        XCTAssertEqual(RangeFixture.ranges, ["bytes=0-524287", "bytes=524288-599999", "bytes=524288-599999"])
    }
    func testWrongContentRangeIsRejected() async throws {
        let session = fixtureSession(); defer { session.invalidateAndCancel() }
        RangeFixture.set(payload: Data(repeating: 3, count: 200), malformed: true, failSecondOnce: false)
        let asset = EasyTierRuntime.Asset(url: URL(string: "https://runtime.invalid/core.zip")!, sha256: "fixture", size: 200)
        do { _ = try await EasyTierRuntime.download(asset, session: session, progress: { _ in }); XCTFail("Malformed range accepted") }
        catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
    }
    private func fixtureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RangeFixture.self]
        return URLSession(configuration: config)
    }
}

private final class RangeFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var malformed = false
    private static var failSecond = false
    private static var requests: [String] = []
    static var ranges: [String] { lock.withLock { requests } }
    static func set(payload: Data, malformed: Bool, failSecondOnce: Bool) {
        lock.withLock { Self.payload = payload; Self.malformed = malformed; Self.failSecond = failSecondOnce; requests = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "runtime.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.lock.withLock { () -> (Data, Bool, Bool) in
            Self.requests.append(request.value(forHTTPHeaderField: "Range") ?? "")
            let fail = Self.failSecond && Self.requests.count == 2
            return (Self.payload, Self.malformed, fail)
        }
        if state.2 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let range = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-")
        let start = Int(range[0])!, end = Int(range[1])!
        let bytes = state.0.subdata(in: start..<(end + 1))
        let contentRange = state.1 ? "bytes 1-200/200" : "bytes \(start)-\(end)/\(state.0.count)"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": contentRange, "Content-Length": String(bytes.count)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

import CryptoKit
import Foundation
import XCTest
@testable import PCLCore

final class JavaInstallerTests: XCTestCase {
    func testVerifiedArchiveIsInstalledAndMismatchedArchiveIsRejected() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PCL-Java-Test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let bin = root.appendingPathComponent("fixture/Contents/Home/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("java")
        try Data("""
        #!/bin/sh
        echo 'java.version = 21.0.1'
        echo 'java.vendor = Test'
        echo 'os.arch = aarch64'

        """.utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let archive = root.appendingPathComponent("fixture.tar.gz")
        let tar = try NativeProcess.capture(URL(fileURLWithPath: "/usr/bin/tar"),
            ["-czf", archive.path, "-C", root.path, "fixture"])
        XCTAssertEqual(tar.status, 0)
        let bytes = try Data(contentsOf: archive)
        JavaDownloadFixture.archive = bytes
        defer {
            JavaDownloadFixture.archive = Data()
            JavaDownloadFixture.zuluUnavailable = false
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JavaDownloadFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let rejected = root.appendingPathComponent("rejected")
        do {
            _ = try await JavaInstaller.install(major: 17, architecture: "arm64", in: rejected, sources: [.zulu], session: session) { _ in }
            XCTFail("Expected SHA-256 mismatch to reject the archive")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("校验失败"))
        }
        XCTAssertFalse(fm.fileExists(atPath: rejected.path))

        let destination = root.appendingPathComponent("installed")
        let runtime = try await JavaInstaller.install(major: 21, architecture: "arm64", in: destination, session: session) { _ in }
        XCTAssertEqual(runtime.majorVersion, 21)
        XCTAssertEqual(runtime.architecture, "arm64")
        XCTAssertEqual(JavaDiscovery.inspect(executable: runtime.executable), runtime)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: destination.path).count, 1)

        JavaDownloadFixture.zuluUnavailable = true
        let fallback = root.appendingPathComponent("fallback")
        let recovered = try await JavaInstaller.install(major: 21, architecture: "arm64", in: fallback, session: session) { _ in }
        XCTAssertEqual(JavaDiscovery.inspect(executable: recovered.executable), recovered)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: fallback.path).count, 1)
    }

    func testRealZuluInstall() async throws {
        guard ProcessInfo.processInfo.environment["PCL_JAVA_INSTALL_SMOKE"] == "1" else {
            throw XCTSkip("Set PCL_JAVA_INSTALL_SMOKE=1 for an actual Zulu download")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PCL-Zulu-Smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try await JavaInstaller.install(major: 8, architecture: InstallPlatform.architecture, in: root, sources: [.zulu]) { _ in }
        XCTAssertEqual(runtime.majorVersion, 8)
        XCTAssertEqual(JavaDiscovery.inspect(executable: runtime.executable), runtime)
    }
}

private final class JavaDownloadFixture: URLProtocol {
    static var archive = Data()
    static var zuluUnavailable = false
    private static let good = "01234567-0000-0000-0000-000000000021"
    private static let bad = "01234567-0000-0000-0000-000000000017"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let hash = SHA256.hash(data: Self.archive).map { String(format: "%02x", $0) }.joined()
        let data: Data
        var status = 200
        if url.host == "corretto.aws" {
            data = url.path.contains("/latest_sha256/") ? Data(hash.utf8) : Self.archive
        } else if Self.zuluUnavailable {
            status = 503
            data = Data()
        } else {
            switch url.lastPathComponent {
            case "fixture.tar.gz":
                data = Self.archive
            case Self.good, Self.bad:
                let checksum = url.lastPathComponent == Self.good ? hash : String(repeating: "0", count: 64)
                data = Data("""
                {"download_url":"https://cdn.azul.com/fixture.tar.gz","sha256_hash":"\(checksum)","size":1000}
                """.utf8)
            default:
                let id = url.query?.contains("java_version=21") == true ? Self.good : Self.bad
                data = Data("[{\"package_uuid\":\"\(id)\"}]".utf8)
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

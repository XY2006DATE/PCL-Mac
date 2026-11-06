import CryptoKit
import Foundation

public enum JavaInstaller {
    public enum Source: String, CaseIterable, Codable, Sendable {
        case zulu = "Azul Zulu"
        case corretto = "Amazon Corretto"
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PCL-SwiftUI/Java", isDirectory: true)
    }

    private struct Package: Decodable {
        let packageUUID: UUID
        enum CodingKeys: String, CodingKey { case packageUUID = "package_uuid" }
    }

    private struct Archive: Decodable {
        let downloadURL: URL
        let sha256: String
        enum CodingKeys: String, CodingKey {
            case downloadURL = "download_url", sha256 = "sha256_hash"
        }
    }

    public static func install(major: Int, architecture: String, preferredSource: Source = .zulu,
                               progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> JavaRuntime {
        let sources = [preferredSource] + Source.allCases.filter { $0 != preferredSource }
        return try await install(major: major, architecture: architecture, in: directory, sources: sources, progress: progress)
    }

    static func install(major: Int, architecture: String, in directory: URL, sources: [Source] = Source.allCases,
                        session: URLSession = .shared, progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> JavaRuntime {
        guard major >= 8, ["arm64", "x86_64"].contains(architecture) else {
            throw LauncherError.invalidJava("不支持下载 Java \(major)（\(architecture)）。")
        }
        let title = "安装 Java \(major)（\(architecture)）"
        let monitor = InstallTaskMonitor(title: title, stages: [.init(id: "java", title: title)], progress: progress)
        monitor.begin("java", message: title)
        do {
            let file = try await download(major: major, architecture: architecture, sources: sources, session: session, monitor: monitor)
            defer { try? FileManager.default.removeItem(at: file) }
            monitor.update("java", fraction: 0.9, message: "正在安装 Java \(major)")
            let runtime = try unpack(file, directory: directory, major: major, architecture: architecture)
            monitor.complete("java", message: "Java \(major) 安装完成")
            return runtime
        } catch {
            if Task.isCancelled || error is CancellationError {
                monitor.cancel()
                throw CancellationError()
            }
            monitor.fail("java", message: error.localizedDescription)
            throw error
        }
    }

    private static func download(major: Int, architecture: String, sources: [Source], session: URLSession,
                                 monitor: InstallTaskMonitor) async throws -> URL {
        var failures: [String] = []
        for source in sources {
            try Task.checkCancellation()
            do {
                monitor.begin("java", message: "正在查询 \(source.rawValue) Java \(major)", resetFraction: true)
                let archive = try await resolve(source, major: major, architecture: architecture, session: session)
                let url = archive.downloadURL
                let host = source == .zulu ? "cdn.azul.com" : "corretto.aws"
                guard url.scheme == "https", url.host == host, url.lastPathComponent.hasSuffix(".tar.gz"),
                      archive.sha256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
                    throw LauncherError.invalidJava("安装包的下载地址或 SHA-256 无效。")
                }
                monitor.update("java", fraction: 0.05, message: "正在下载 \(source.rawValue) Java \(major)")
                let (file, response) = try await InstallProgressContext.$current.withValue(monitor) {
                    try await PCLHTTPS.download(for: URLRequest(url: url, timeoutInterval: 60), session: session) { received, expected in
                        guard expected > 0 else { return }
                        let fraction = min(1, Double(received) / Double(expected))
                        monitor.update("java", fraction: 0.05 + 0.8 * fraction)
                    }
                }
                do {
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else {
                        throw LauncherError.invalidJava("安装包下载失败。")
                    }
                    guard try sha256(file) == archive.sha256.lowercased() else {
                        throw LauncherError.invalidJava("安装包 SHA-256 校验失败。")
                    }
                    try Task.checkCancellation()
                    return file
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                failures.append("\(source.rawValue) · \(error.localizedDescription)")
            }
        }
        throw LauncherError.invalidJava("下载 Java \(major)（\(architecture)）失败。\n" + failures.joined(separator: "\n"))
    }

    private static func resolve(_ source: Source, major: Int, architecture: String, session: URLSession) async throws -> Archive {
        switch source {
        case .zulu:
            let base = "https://api.azul.com/metadata/v1/zulu/packages/"
            let query = "?java_version=\(major)&os=macos&arch=\(architecture)&archive_type=tar.gz&java_package_type=jdk&release_status=ga&availability_types=CA&javafx_bundled=false&latest=true"
            let packages = try JSONDecoder().decode([Package].self, from: await metadata(URL(string: base + query)!, session: session))
            guard let package = packages.first else {
                throw LauncherError.invalidJava("暂无所需版本的安装包。")
            }
            let detail = URL(string: base + package.packageUUID.uuidString.lowercased())!
            return try JSONDecoder().decode(Archive.self, from: await metadata(detail, session: session))
        case .corretto:
            let arch = architecture == "arm64" ? "aarch64" : "x64"
            let name = "amazon-corretto-\(major)-\(arch)-macos-jdk.tar.gz"
            let base = "https://corretto.aws/downloads/"
            let checksum = try await metadata(URL(string: base + "latest_sha256/" + name)!, session: session)
            return Archive(downloadURL: URL(string: base + "latest/" + name)!,
                           sha256: String(decoding: checksum, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func metadata(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await PCLHTTPS.data(for: URLRequest(url: url, timeoutInterval: 30), session: session)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else {
            throw LauncherError.invalidJava("无法读取安装包信息（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        return data
    }

    private static func unpack(_ file: URL, directory: URL, major: Int, architecture: String) throws -> JavaRuntime {
        let fm = FileManager.default
        try Task.checkCancellation()
        let id = UUID().uuidString
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let installRoot = directory.resolvingSymlinksInPath()
        let stage = installRoot.appendingPathComponent(".installing-\(id)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let tar = try NativeProcess.capture(URL(fileURLWithPath: "/usr/bin/tar"),
            ["-xzf", file.path, "--no-same-owner", "--no-same-permissions", "-C", stage.path], timeout: 120)
        guard tar.status == 0 else { throw LauncherError.invalidJava("无法解压 Java 安装包。") }
        try Task.checkCancellation()
        let javaPath = "Contents/Home/bin/java"
        let bundles = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        guard let bundle = bundles.first(where: { candidate in
            let resolved = candidate.resolvingSymlinksInPath()
            let executable = candidate.appendingPathComponent(javaPath).resolvingSymlinksInPath()
            return resolved.path.hasPrefix(stage.path + "/") && executable.path.hasPrefix(resolved.path + "/")
                && fm.isExecutableFile(atPath: executable.path)
        }), let runtime = JavaDiscovery.inspect(executable: bundle.appendingPathComponent(javaPath)),
              runtime.majorVersion == major, runtime.architecture == architecture else {
            let rosetta = architecture == "x86_64" && InstallPlatform.architecture == "arm64" ? "请确认这台 Mac 已安装 Rosetta。" : ""
            throw LauncherError.invalidJava("下载的 Java 无法运行，或与所需版本及架构不符。\(rosetta)")
        }
        try Task.checkCancellation()
        let destination = installRoot.appendingPathComponent("pcl-java-\(major)-\(architecture)-\(id).jdk", isDirectory: true)
        try fm.moveItem(at: bundle, to: destination)
        return JavaRuntime(executable: destination.appendingPathComponent(javaPath),
                           majorVersion: runtime.majorVersion, architecture: runtime.architecture, displayName: runtime.displayName)
    }

    private static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

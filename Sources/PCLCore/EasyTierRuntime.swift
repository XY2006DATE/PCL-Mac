import Foundation
import CryptoKit
import Darwin

public actor EasyTierRuntime {
    public static let version = "2.6.4"
    public struct Binaries: Sendable { public let core: URL; public let cli: URL }
    public enum Architecture: String, Sendable { case arm64 = "aarch64", x86_64 }
    public struct Asset: Sendable {
        public let url: URL
        public let sha256: String
        public let size: Int
    }
    public static func asset(for architecture: Architecture) -> Asset {
        let sha = architecture == .arm64 ? "4be1882d1aa36d31c1d6ba0596f2cf8a097e371f8da124212324b2e0f8df7e4b" : "89fc28a6e6995259d76ce3f11775220e8a21c760e94df91a6a9db30a69b6982e"
        return Asset(url: URL(string: "https://github.com/EasyTier/EasyTier/releases/download/v\(version)/easytier-macos-\(architecture.rawValue)-v\(version).zip")!, sha256: sha,
                     size: architecture == .arm64 ? 30_174_017 : 33_733_545)
    }
    public static var nativeArchitecture: Architecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
    private var preparing = false
    private let directory: URL
    public init(directory: URL) { self.directory = directory.resolvingSymlinksInPath() }
    private struct Receipt: Codable { let archive: String; let core: String; let cli: String }

    public func prepare(progress: @Sendable (String) -> Void) async throws -> Binaries {
        guard !preparing else { throw PCLLinkError.invalid("联机模块仍在准备中，请稍后重试。") }
        preparing = true; defer { preparing = false }
        let asset = Self.asset(for: Self.nativeArchitecture)
        let target = directory.appendingPathComponent(Self.version + "/" + Self.nativeArchitecture.rawValue)
        if let cached = try? Self.cached(at: target, archive: asset.sha256) { return cached }
        progress("下载 EasyTier \(Self.version) 联机模块")
        let zip = try await Self.download(asset, progress: progress)
        defer { try? FileManager.default.removeItem(at: zip) }
        progress("校验并安装联机模块")
        let installation = Task.detached { try Self.install(zip: zip, asset: asset, target: target) }
        return try await withTaskCancellationHandler { try await installation.value } onCancel: { installation.cancel() }
    }
    static func install(zip: URL, asset: Asset, target: URL) throws -> Binaries {
        guard try digest(zip) == asset.sha256 else { throw PCLLinkError.invalid("联机模块 SHA-256 校验失败，请重试。") }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stage = target.deletingLastPathComponent().appendingPathComponent("install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let archive = try ModpackZIPArchive(url: zip)
        for name in ["easytier-core", "easytier-cli"] {
            let entries = archive.entries.filter { !$0.isDirectory && ($0.path as NSString).lastPathComponent == name }
            guard entries.count == 1 else { throw PCLLinkError.invalid("联机模块压缩包缺少或重复包含 \(name)。") }
            let file = stage.appendingPathComponent(name)
            try archive.write(entries[0], to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let receipt = Receipt(archive: asset.sha256, core: try Self.digest(stage.appendingPathComponent("easytier-core")), cli: try Self.digest(stage.appendingPathComponent("easytier-cli")))
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("receipt.json"), options: .atomic)
        try Task.checkCancellation()
        // This directory contains only the downloaded, replaceable runtime.
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: stage)
        } else { try FileManager.default.moveItem(at: stage, to: target) }
        return try Self.cached(at: target, archive: asset.sha256)
    }
    static func download(_ asset: Asset, session: URLSession = .shared, progress: @Sendable (String) -> Void) async throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("PCL-EasyTier-" + UUID().uuidString + ".zip")
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw PCLLinkError.invalid("无法创建联机下载临时文件。") }
        let file = try FileHandle(forWritingTo: target)
        var succeeded = false
        defer { try? file.close(); if !succeeded { try? FileManager.default.removeItem(at: target) } }
        var offset = 0
        while offset < asset.size {
            try Task.checkCancellation()
            let end = min(asset.size - 1, offset + 512 * 1024 - 1)
            var lastError: Error?
            var completed = false
            for attempt in 0..<3 {
                do {
                    var request = URLRequest(url: asset.url); request.timeoutInterval = 120
                    request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                    let (chunk, response) = try await PCLHTTPS.download(for: request, session: session)
                    defer { try? FileManager.default.removeItem(at: chunk) }
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    let data = try Data(contentsOf: chunk)
                    if offset == 0 && http.statusCode == 200 && data.count == asset.size {
                        try file.write(contentsOf: data); offset = asset.size
                    } else {
                        guard http.statusCode == 206, data.count == end - offset + 1,
                              http.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(asset.size)" else { throw URLError(.badServerResponse) }
                        try file.write(contentsOf: data); offset = end + 1
                    }
                    completed = true; break
                } catch is CancellationError { throw CancellationError() }
                catch { lastError = error; if attempt < 2 { try await Task.sleep(nanoseconds: 300_000_000) } }
            }
            guard completed else { throw lastError ?? URLError(.cannotLoadFromNetwork) }
            progress("下载联机模块：\(offset * 100 / asset.size)%")
        }
        try file.synchronize(); succeeded = true; return target
    }
    static func cached(at target: URL, archive: String) throws -> Binaries {
        guard target.resolvingSymlinksInPath() == target.standardizedFileURL else { throw PCLLinkError.invalid("联机模块目录不能是符号链接。") }
        let core = target.appendingPathComponent("easytier-core"), cli = target.appendingPathComponent("easytier-cli")
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: target.appendingPathComponent("receipt.json")))
        for file in [core, cli] {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, FileManager.default.isExecutableFile(atPath: file.path) else { throw PCLLinkError.invalid("联机模块文件无效。") }
        }
        guard receipt.archive == archive, try digest(core) == receipt.core, try digest(cli) == receipt.cli else { throw PCLLinkError.invalid("联机模块文件已改变，需要重新下载。") }
        return Binaries(core: core, cli: cli)
    }
    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Controls only its own child process; termination never searches by process name.
final class LinkProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var buffer = Data()
    private var output: (@Sendable (String) -> Void)?
    private var pipe: Pipe?

    var isRunning: Bool { lock.withLock { process?.isRunning == true } }
    func start(executable: URL, arguments: [String], output: (@Sendable (String) -> Void)? = nil) throws {
        let task = Process(), pipe = Pipe()
        task.executableURL = executable; task.arguments = arguments
        task.standardOutput = pipe; task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        self.process = task; self.pipe = pipe; self.output = output
        lock.unlock()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            self?.receive(bytes)
        }
        do { try task.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; throw error }
        if lock.withLock({ cancelled }) { stop() }
    }
    private func receive(_ data: Data) {
        let delivery: ([String], (@Sendable (String) -> Void)?) = lock.withLock {
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 10) {
                lines.append(String(decoding: buffer[..<newline], as: UTF8.self)); buffer.removeSubrange(...newline)
            }
            if buffer.count > 65536 { buffer.removeAll(keepingCapacity: false) }
            return (lines, output)
        }
        for line in delivery.0 { delivery.1?(line) }
    }
    func stop() {
        let task = lock.withLock { cancelled = true; return process }
        guard let task, task.isRunning else { return }
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
        }
    }
    deinit { pipe?.fileHandleForReading.readabilityHandler = nil; if process?.isRunning == true { process?.terminate() } }
}

/// Bounded short-lived RPC CLI invocation. Stdout is never written to disk.
enum LinkCommand {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 4) async throws -> Data {
        let state = CommandState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.run(executable, arguments, timeout: timeout, continuation: continuation)
            }
        } onCancel: { state.cancel() }
    }
    private final class CommandState: @unchecked Sendable {
        let lock = NSLock()
        var task: Process?
        var waiter: CheckedContinuation<Data, Error>?
        var cancelled = false
        var pipe: Pipe?
        func run(_ executable: URL, _ args: [String], timeout: TimeInterval, continuation: CheckedContinuation<Data, Error>) {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable; process.arguments = args; process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            lock.lock(); waiter = continuation; task = process; self.pipe = pipe
            let wasCancelled = cancelled; lock.unlock()
            guard !wasCancelled else { finish(.failure(CancellationError())); return }
            do { try process.run() } catch { finish(.failure(error)); return }
            if lock.withLock({ cancelled }) { cancel() }
            DispatchQueue.global().async { [self] in
                var output = Data(), tooLarge = false
                while true {
                    do {
                        guard let data = try pipe.fileHandleForReading.read(upToCount: 65536), !data.isEmpty else { break }
                        if output.count + data.count <= 1024 * 1024 { output.append(data) }
                        else { tooLarge = true; cancel() }
                    } catch { break }
                }
                process.waitUntilExit()
                if lock.withLock({ cancelled }) { finish(.failure(CancellationError())) }
                else if process.terminationStatus != 0 || tooLarge { finish(.failure(PCLLinkError.invalid("联机模块 RPC 查询失败。"))) }
                else { finish(.success(output)) }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                let pending = lock.withLock { waiter != nil }
                if pending { cancel(); finish(.failure(PCLLinkError.invalid("联机模块 RPC 查询超时。"))) }
            }
        }
        func cancel() {
            let process = lock.withLock { cancelled = true; return task }
            if let process, process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
            }
        }
        func finish(_ result: Result<Data, Error>) {
            let continuation = lock.withLock { let v = waiter; waiter = nil; return v }
            continuation?.resume(with: result)
        }
    }
}

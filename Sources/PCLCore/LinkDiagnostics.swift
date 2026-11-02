import Foundation
import Darwin

/// The UI stores a bounded in-memory tail only. No multiplayer logs are persisted.
public struct LinkLogBuffer {
    public static let maximumBytes = 64 * 1024
    public static let maximumLines = 200
    public private(set) var lines: [String] = []
    public private(set) var byteCount = 0
    public init() {}
    public mutating func append(_ text: String) {
        let line = String(decoding: text.utf8.prefix(2048), as: UTF8.self)
        guard !line.isEmpty else { return }
        lines.append(line); byteCount += line.utf8.count + 1
        while lines.count > Self.maximumLines || byteCount > Self.maximumBytes {
            byteCount -= lines.removeFirst().utf8.count + 1
        }
    }
}

/// Runs before dispatching output to the main actor, bounding callback work as
/// well as storage. Timestamp/duration variations do not bypass duplicate limits.
struct LinkLogLimiter {
    private var recent: [String: TimeInterval] = [:]
    private var window: TimeInterval = -1
    private var delivered = 0
    private var suppressed = 0
    mutating func accept(_ raw: String, now: TimeInterval) -> String? {
        let line = String(decoding: raw.utf8.prefix(2048), as: UTF8.self)
            .replacingOccurrences(of: #"\u001B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let key: String
        if line.contains("reconn_tasks done") { key = "connector-retry" }
        else if line.contains("peer rpc transport read aborted") { key = "rpc-read-aborted" }
        else if line.contains("connector:") && (line.contains("removed") || line.contains("remove later")) { key = "connector-removed" }
        else if line == "Caused by:" || line.contains("Invalid Url:") || line.contains("get redirected url failed") { key = "discovery-invalid-response" }
        else {
            key = line.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}T\S+\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\b\d+(?:\.\d+)?(?:ms|s)\b"#, with: "<duration>", options: .regularExpression)
        }
        if now - window >= 1 { window = now; delivered = 0 }
        if delivered >= 4 || recent[key].map({ now - $0 < 30 }) == true { suppressed += 1; return nil }
        if recent.count >= 128 { recent = recent.filter { now - $0.value < 30 }; if recent.count >= 128 { recent.removeAll(keepingCapacity: true) } }
        recent[key] = now; delivered += 1
        let suffix = suppressed > 0 ? "\n[已合并 \(suppressed) 条重复或过密日志]" : ""
        suppressed = 0
        return line + suffix
    }
}

enum LinkRuntimeOptions {
    static let logging = ["--console-log-level", "warn", "--file-log-level", "off"]
}

/// Clean only this launcher's abandoned room metadata, never game/runtime data.
enum LinkSessionStorage {
    private struct Owner: Codable { let pid: Int32 }
    static func create(in base: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for old in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            guard UUID(uuidString: old.lastPathComponent) != nil,
                  (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let data = try? Data(contentsOf: old.appendingPathComponent("owner.json")), data.count <= 128,
                  let owner = try? JSONDecoder().decode(Owner.self, from: data), owner.pid > 1,
                  kill(owner.pid, 0) != 0, errno == ESRCH else { continue }
            try? fm.removeItem(at: old)
        }
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let bytes = try JSONEncoder().encode(Owner(pid: getpid()))
            guard fm.createFile(atPath: folder.appendingPathComponent("owner.json").path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        } catch { try? fm.removeItem(at: folder); throw error }
        return folder
    }
}

import Foundation

/// Uses the pinned core's actual handshake status, never just an open TCP socket.
struct LinkConnector: Decodable, Equatable {
    struct Address: Decodable, Equatable { let url: String }
    let url: Address
    let status: Int
    var connected: Bool { status == 0 }
    static func parse(_ data: Data) throws -> [Self] {
        guard data.count <= 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let list = try JSONDecoder().decode([Self].self, from: data)
        guard list.count <= 256, list.allSatisfy({ (0...2).contains($0.status) && $0.url.url.utf8.count <= 1024 }) else { throw URLError(.cannotParseResponse) }
        return list
    }
}

/// All state is per room. A failed discovery entry is removed from EasyTier's
/// fast reconnect loop, then admitted for one bounded probe after its cooldown.
struct LinkNodePolicy {
    enum Action: Equatable { case remove(String), add(String) }
    private struct Node {
        let url: String
        var active = true
        var since: TimeInterval
        var failures = 0
        var retryAt: TimeInterval = 0
    }
    private var nodes: [Node]
    init(peers: [String], now: TimeInterval) {
        var seen = Set<String>()
        nodes = peers.filter { seen.insert($0).inserted }.map { Node(url: $0, since: now) }
    }
    mutating func actions(status: [LinkConnector], now: TimeInterval) -> [Action] {
        let connected = Set(status.filter(\.connected).map(\.url.url))
        var result: [Action] = []
        for i in nodes.indices where nodes[i].active {
            if connected.contains(nodes[i].url) {
                nodes[i].since = now
            } else {
                let grace: TimeInterval = nodes[i].url.hasPrefix("https://") ? 25 : 8
                if now - nodes[i].since >= grace { result.append(.remove(nodes[i].url)) }
            }
        }
        // Keep connected entries. Two independent discoveries are sufficient;
        // avoid probing dead backups forever when the room is already reachable.
        if connected.count < 2 {
            let probing = nodes.filter { $0.active && !connected.contains($0.url) }.count
            let slots = max(0, 2 - probing)
            let waiting = nodes.filter { !$0.active && now >= $0.retryAt }.sorted { $0.retryAt < $1.retryAt }
            result += waiting.prefix(slots).map { .add($0.url) }
        }
        return Array(result.prefix(4))
    }
    mutating func applied(_ action: Action, now: TimeInterval) {
        let url: String
        switch action { case .add(let value), .remove(let value): url = value }
        guard let i = nodes.firstIndex(where: { $0.url == url }) else { return }
        switch action {
        case .remove:
            nodes[i].active = false
            nodes[i].failures = min(nodes[i].failures + 1, 5)
            nodes[i].retryAt = now + min(300, 30 * pow(2, Double(nodes[i].failures - 1)))
        case .add:
            nodes[i].active = true; nodes[i].since = now
        }
    }
}

enum LinkNodeMaintenance {
    static func run(cli: URL, rpc: UInt16, peers: [String], event: @escaping @Sendable (PCLRoomEvent) -> Void) async {
        var policy = LinkNodePolicy(peers: peers, now: ProcessInfo.processInfo.systemUptime)
        while !Task.isCancelled {
            do {
                let data = try await LinkCommand.run(cli, ["-p", "127.0.0.1:\(rpc)", "-o", "json", "connector", "list"])
                let status = try LinkConnector.parse(data)
                try Task.checkCancellation()
                let now = ProcessInfo.processInfo.systemUptime
                for action in policy.actions(status: status, now: now) {
                    try Task.checkCancellation()
                    let verb: String, url: String
                    switch action { case .remove(let value): verb = "remove"; url = value
                    case .add(let value): verb = "add"; url = value }
                    _ = try await LinkCommand.run(cli, ["-p", "127.0.0.1:\(rpc)", "connector", verb, url])
                    try Task.checkCancellation()
                    policy.applied(action, now: ProcessInfo.processInfo.systemUptime)
                    event(.output(verb == "remove" ? "已暂停不可用入口的快速重试；保留已连通节点，稍后自动探测备用入口。" : "正在自动探测冷却后的备用入口。"))
                }
            } catch is CancellationError { return }
            catch { /* Query failure is not evidence that every node is dead. */ }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
    }
}

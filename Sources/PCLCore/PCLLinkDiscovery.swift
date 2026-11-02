import Foundation
import Darwin

/// A self-contained Mac room link carries the discovery entry points selected by
/// its host. Joining must not depend on both clients fetching the same catalog.
public struct PCLRoomLink: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let prefix = "PCLM1."
    public let invite: PCLInvite
    public let peers: [String]
    public var description: String { "PCL Mac automatic room (credentials redacted)" }
    public var debugDescription: String { description }
    private struct Payload: Codable { let version: Int; let invite: String; let peers: [String] }
    public init(invite: PCLInvite, peers: [String]) throws {
        try invite.requireCustomNode()
        self.invite = invite; self.peers = try PCLLinkPeers.parse(peers.joined(separator: ","))
    }
    public init(_ text: String) throws {
        guard text.utf8.count <= 8192 else { throw PCLLinkError.invalid("连接码过长。") }
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = value.range(of: "【"), let b = value.range(of: "】", range: a.upperBound..<value.endIndex) {
            value = String(value[a.upperBound..<b.lowerBound])
        }
        guard value.hasPrefix(Self.prefix) else { throw PCLLinkError.invalid("自动连接码格式无效。") }
        var encoded = String(value.dropFirst(Self.prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), bytes.count <= 4096,
              let payload = try? JSONDecoder().decode(Payload.self, from: bytes), payload.version == 1 else {
            throw PCLLinkError.invalid("自动连接码已损坏或版本不受支持，请重新复制完整连接码。")
        }
        try self.init(invite: PCLInvite(payload.invite), peers: payload.peers)
    }
    public var code: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try! encoder.encode(Payload(version: 1, invite: invite.code, peers: peers)).base64EncodedString()
        return Self.prefix + encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public actor PCLLinkDiscovery {
    // Sources: PCL CE EasyTierEntity._fallbackNodeLinks and Astral's published
    // server directory. They are discovery candidates, not an uptime
    // guarantee. Real readiness is determined by EasyTier's peer RPC below.
    public static let fallbackPeers = ["https://etnode.zkitefly.eu.org/node2", "https://etnode.zkitefly.eu.org/node1",
                                       "tcp://public2.easytier.cn:54321", "udp://turn.sc.629957.xyz:11010"]
    public static let catalogURL = URL(string: "https://uptime.easytier.cn/api/nodes?page=1&per_page=50&is_active=true")!
    public static let alternateCatalogURL = URL(string: "https://raw.githubusercontent.com/ldoubil/astral.github.io/main/src/data/server.json")!
    // The same public discovery URLs used by PCL CE's Scaffolding implementation.
    // EasyTier resolves these HTTPS URLs into the operator's current peer address.
    public static func scaffoldingPeers(_ selected: [String]) throws -> [String] {
        try PCLLinkPeers.parse((selected + ["tcp://public.easytier.top:11010", "tcp://public2.easytier.cn:54321",
            "https://etnode.zkitefly.eu.org/node1", "https://etnode.zkitefly.eu.org/node2",
            "https://etnode.zkitefly.eu.org/-node1", "https://etnode.zkitefly.eu.org/-node2"]).joined(separator: ","), maximum: 16)
    }
    private let cache: URL
    private struct Cache: Codable { let date: Date; let peers: [String] }
    public init(cache: URL) { self.cache = cache }

    public func resolve(session: URLSession = .shared) async throws -> [String] {
        try Task.checkCancellation()
        // Keep a validated catalog for up to one day; no room credentials are cached.
        if let saved = try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: cache)),
           Date().timeIntervalSince(saved.date) >= 0, Date().timeIntervalSince(saved.date) < 86400,
           let peers = try? Self.validPublicPeers(saved.peers), !peers.isEmpty { return Self.select(peers) }
        do {
            let peers = try await withThrowingTaskGroup(of: [String].self) { group in
                for url in [Self.catalogURL, Self.alternateCatalogURL] {
                    group.addTask {
                        var request = URLRequest(url: url); request.timeoutInterval = 7
                        let (data, response) = try await PCLHTTPS.data(for: request, session: session)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        return try Self.parseCatalog(data)
                    }
                }
                while !group.isEmpty {
                    do {
                        if let peers = try await group.next() { group.cancelAll(); return peers }
                    } catch { try Task.checkCancellation() }
                }
                throw URLError(.cannotConnectToHost)
            }
            try Task.checkCancellation()
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let bytes = try? JSONEncoder().encode(Cache(date: Date(), peers: peers)) { try? bytes.write(to: cache, options: .atomic) }
            return Self.select(peers)
        } catch {
            try Task.checkCancellation()
            return Self.fallbackPeers
        }
    }
    private static func select(_ peers: [String]) -> [String] {
        // A shared CE entry point is kept alongside rotating catalog candidates.
        // The operator may change its underlying address without an app update.
        var result = ["https://etnode.zkitefly.eu.org/node2"]
        for peer in peers.shuffled() where !result.contains(peer) {
            result.append(peer); if result.count == 4 { break }
        }
        return result
    }
    static func parseCatalog(_ data: Data) throws -> [String] {
        struct Catalog: Decodable {
            struct Node: Decodable { let address: String; let is_active: Bool; let allow_relay: Bool }
            struct Page: Decodable { let items: [Node] }
            let success: Bool; let data: Page
        }
        guard data.count <= 1024 * 1024 else { throw PCLLinkError.invalid("公共节点目录过大。") }
        let peers: [String]
        if let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            guard catalog.success, catalog.data.items.count <= 1000 else { throw URLError(.badServerResponse) }
            peers = try validPublicPeers(catalog.data.items.filter { $0.is_active && $0.allow_relay }.map(\.address))
        } else {
            struct PublishedServer: Decodable { let url: String }
            let list = try JSONDecoder().decode([PublishedServer].self, from: data)
            guard list.count <= 1000 else { throw URLError(.badServerResponse) }
            peers = try validPublicPeers(list.map { "tcp://" + $0.url })
        }
        guard !peers.isEmpty else { throw URLError(.resourceUnavailable) }
        return peers
    }
    private static func validPublicPeers(_ values: [String]) throws -> [String] {
        var result: [String] = []
        for value in values.prefix(1000) {
            guard value.count <= 512, let url = URLComponents(string: value), let host = url.host?.lowercased(),
                  !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), host != "localhost",
                  !host.contains(":"), // Catalog transport uses public IPv4/DNS; direct IPv6 hints are separate.
                  !isPrivateIPv4(host), let parsed = try? PCLLinkPeers.parse(value),
                  let peer = parsed.first, !result.contains(peer) else { continue }
            result.append(peer)
        }
        return result
    }
    private static func isPrivateIPv4(_ host: String) -> Bool {
        var address = in_addr()
        guard host.withCString({ inet_aton($0, &address) }) != 0 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        let parts = [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        return parts[0] == 0 || parts[0] == 10 || parts[0] == 127 || parts[0] >= 224 ||
            (parts[0] == 172 && (16...31).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254) ||
            (parts[0] == 198 && (18...19).contains(parts[1])) ||
            (parts[0] == 100 && (64...127).contains(parts[1]))
    }
    /// Only real interface addresses are shared, never VPN/fake-IP DNS answers.
    static func directPeers(port: UInt16) -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var v6: [String] = [], v4: [String] = []
        var item = list
        while let entry = item {
            defer { item = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name), flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("wl"),
                  let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if family == AF_INET6 {
                // Public unicast IPv6 only; link-local/ULA addresses cannot reach another household.
                guard text.first == "2" || text.first == "3", !text.contains("%") else { continue }
                if !v6.contains(text) { v6.append(text) }
            } else if !text.hasPrefix("169.254."), !text.hasPrefix("198.18."), !text.hasPrefix("198.19.") {
                if !v4.contains(text) { v4.append(text) }
            }
        }
        return Array((v6.prefix(1).flatMap { ["tcp://[\($0)]:\(port)", "udp://[\($0)]:\(port)"] } +
                      v4.prefix(1).flatMap { ["tcp://\($0):\(port)", "udp://\($0):\(port)"] }).prefix(4))
    }
}

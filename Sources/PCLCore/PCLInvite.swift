import Foundation

public enum PCLLinkError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// Pure Connect Labeling v02. Room credentials must never be included in logs.
public struct PCLInvite: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let port: UInt16
    public let networkName: String
    public let networkSecret: String
    public let nodeID: UInt16
    public let code: String
    public var description: String { "PCL v02 room (port \(port), credentials redacted)" }
    public var debugDescription: String { description }

    public init(_ input: String) throws {
        guard input.utf8.count <= 4096 else { throw PCLLinkError.invalid("邀请码过长。") }
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for (left, right) in [("【", "】"), ("[", "]")] {
            if let a = value.range(of: left), let b = value.range(of: right, range: a.upperBound..<value.endIndex) {
                value = String(value[a.upperBound..<b.lowerBound]); break
            }
        }
        value = value.uppercased().replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
        if value.hasPrefix("U/") { throw PCLLinkError.invalid("这是 Scaffolding 房间码，暂不支持加入。请使用原版 PCL 02 邀请码。") }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0].count == 5, parts[0].hasPrefix("P"),
              parts[1].count == 5, parts[2].count == 5, parts[3].count == 5,
              [parts[1], parts[2]].allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) } }),
              let parsedPort = UInt16(parts[0].dropFirst(), radix: 16), parsedPort > 1024,
              let node = UInt16(parts[3].suffix(3), radix: 16) else {
            throw PCLLinkError.invalid("邀请码格式无效，请复制原版 PCL 生成的完整邀请码。")
        }
        guard parts[3].hasPrefix("02") else { throw PCLLinkError.invalid("暂不支持此邀请码版本，目前仅支持 02。") }
        port = parsedPort; nodeID = node
        networkName = parts[0] + "-" + parts[1]; networkSecret = parts[2]
        code = parts.prefix(4).joined(separator: "-")
    }

    public static func create(port: UInt16) throws -> Self {
        guard port > 1024 else { throw PCLLinkError.invalid("游戏端口应为 1025–65535。") }
        let alphabet = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        var generator = SystemRandomNumberGenerator()
        func randomPart() -> String { String((0..<5).map { _ in alphabet.randomElement(using: &generator)! }) }
        return try Self(String(format: "P%04X", port) + "-" + randomPart() + "-" + randomPart() + "-02000")
    }

    public func requireCustomNode() throws {
        guard nodeID == 0 else { throw PCLLinkError.invalid("此邀请码使用原版 PCL 官方节点编号，暂不支持。免填节点联机请让房主创建 CE／HMCL 的 U/ 自动大厅；原版 PCL 可选用双方共同的自定义节点兼容模式（邀请码结尾为 02000）。") }
    }
    public func redacting(_ text: String) -> String {
        text.replacingOccurrences(of: code, with: "[邀请码已隐藏]")
            .replacingOccurrences(of: networkSecret, with: "[密钥已隐藏]")
            .replacingOccurrences(of: #"\u001B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }
}

public enum PCLLinkPeers {
    public static func parse(_ input: String, maximum: Int = 8) throws -> [String] {
        guard input.utf8.count <= 4096 else { throw PCLLinkError.invalid("自定义节点内容过长。") }
        var seen = Set<String>()
        let peers = try input.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).map { raw -> String in
            guard let url = URLComponents(string: String(raw)), let scheme = url.scheme?.lowercased(),
                  ["tcp", "udp", "ws", "wss", "https"].contains(scheme), let host = url.host, !host.isEmpty,
                  let port = url.port ?? (scheme == "https" ? 443 : nil), (1...65535).contains(port), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, scheme == "https" || url.path.isEmpty || url.path == "/",
                  let normalized = url.url?.absoluteString else {
                throw PCLLinkError.invalid("节点应为 tcp://主机:端口、udp://主机:端口、ws(s)://主机:端口 或 HTTPS 发现地址，不含账号或额外参数。")
            }
            return normalized
        }.filter { seen.insert($0).inserted }
        guard !peers.isEmpty, peers.count <= min(maximum, 16) else { throw PCLLinkError.invalid("节点列表为空或超出数量上限。") }
        return peers
    }
}

public struct PCLLinkConfiguration: Sendable {
    public enum Role: String, Sendable { case host, guest }
    public let invite: PCLInvite
    public let role: Role
    public let peers: [String]
    public let rpcPort: UInt16
    public let listenerPort: UInt16
    public let localPort: UInt16
    public let latencyFirst: Bool
    public let automatic: Bool

    public init(invite: PCLInvite, role: Role, peers: [String], rpcPort: UInt16, listenerPort: UInt16, localPort: UInt16, latencyFirst: Bool = false, automatic: Bool = false) throws {
        try invite.requireCustomNode()
        self.invite = invite; self.role = role; self.peers = try PCLLinkPeers.parse(peers.joined(separator: ","))
        guard [rpcPort, listenerPort, localPort].allSatisfy({ $0 > 1024 }), Set([rpcPort, listenerPort, localPort, invite.port]).count == 4 else {
            throw PCLLinkError.invalid("联机内部端口冲突，请重试。")
        }
        self.rpcPort = rpcPort; self.listenerPort = listenerPort; self.localPort = localPort; self.latencyFirst = latencyFirst; self.automatic = automatic
    }
    public func coreArguments(configFile: URL) -> [String] {
        ["--config-file", configFile.path, "--rpc-portal", "127.0.0.1:\(rpcPort)",
         "--rpc-portal-whitelist", "127.0.0.1/32", "--disable-env-parsing"] + LinkRuntimeOptions.logging
    }
    public var connectionAddress: String { "127.0.0.1:\(localPort)" }
    public var toml: String {
        func quote(_ s: String) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]; return String(data: try! encoder.encode(s), encoding: .utf8)! }
        let allowed = role == .host ? String(invite.port) : "0"
        var text = """
        instance_name = "pcl-mac-room"
        hostname = "\(role == .host ? "Server" : "Client")-PCLMac"
        \(role == .host ? "ipv4 = \"10.114.114.114\"" : "")
        dhcp = \(role == .guest)
        listeners = ["tcp://0.0.0.0:\(listenerPort)", "udp://0.0.0.0:\(listenerPort)"]
        tcp_whitelist = ["\(allowed)"]
        udp_whitelist = ["\(allowed)"]

        [network_identity]
        network_name = \(quote(invite.networkName))
        network_secret = \(quote(invite.networkSecret))

        [flags]
        no_tun = true
        bind_device = false
        use_smoltcp = true
        enable_encryption = true
        encryption_algorithm = "\(automatic ? "aes-gcm" : "chacha20")"
        private_mode = true
        latency_first = \(latencyFirst)
        relay_network_whitelist = ""
        accept_dns = false
        enable_exit_node = false
        """
        for peer in peers { text += "\n\n[[peer]]\nuri = \(quote(peer))" }
        if role == .guest {
            for proto in ["tcp", "udp"] {
                text += "\n\n[[port_forward]]\nproto = \(quote(proto))\nbind_addr = \(quote("127.0.0.1:\(localPort)"))\ndst_addr = \(quote("10.114.114.114:\(invite.port)"))"
            }
        }
        return text + "\n"
    }
}

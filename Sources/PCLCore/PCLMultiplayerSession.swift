import Foundation

public struct PCLLinkPeer: Sendable, Equatable {
    public let hostname: String
    public let ipv4: String
    public let cost: String
    public let latencyMS: Double?
    public var isLocal: Bool { cost.lowercased() == "local" }
    public var isHost: Bool { ipv4 == "10.114.114.114" || ipv4 == "10.114.51.41" }
    public var isPlayer: Bool { isHost || hostname.hasPrefix("Client") || hostname.hasPrefix("scaffolding-mc-server-") || UUID(uuidString: hostname) != nil }
    public var connection: String {
        if isLocal { return "本机" }
        if cost.lowercased() == "p2p" { return "直连" }
        if !cost.isEmpty { return "中继（\(cost)）" }
        return "连接优化中"
    }
    public static func parse(_ data: Data) throws -> [Self] {
        guard data.count <= 1024 * 1024, let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], list.count <= 2048 else {
            throw PCLLinkError.invalid("联机模块返回了无效的节点列表。")
        }
        return try list.map { item in
            guard let name = item["hostname"] as? String, name.count <= 512,
                  let address = (item["ipv4"] ?? item["cidr"]) as? String, let cost = item["cost"] as? String else {
                throw PCLLinkError.invalid("联机模块节点数据不完整。")
            }
            let latency = (item["lat_ms"] as? NSNumber)?.doubleValue ?? Double(item["lat_ms"] as? String ?? "")
            return Self(hostname: name, ipv4: String(address.split(separator: "/").first ?? ""), cost: cost,
                        latencyMS: latency.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        }
    }
}

public struct PCLRoomSnapshot: Sendable {
    public let isHost: Bool
    public let inviteCode: String
    public let gamePort: UInt16
    public let localAddress: String
    public let peers: [PCLLinkPeer]
    public let reconnecting: Bool
    public var automatic: Bool = false
    public var scaffolding: Bool = false
    public var playerNames: [String] = []
    public var playerCount: Int { playerNames.isEmpty ? peers.filter(\.isPlayer).count : playerNames.count }
}

public enum PCLRoomEvent: Sendable {
    case progress(String)
    case output(String)
    case connected(PCLRoomSnapshot)
    case failed(String)
}

public actor PCLMultiplayerSession {
    private let directory: URL
    private let supervisor: URL
    private var core: LinkProcess?
    private var advertisement: LinkLANAdvertisement?
    private var monitor: Task<Void, Never>?
    private var nodeMaintenance: Task<Void, Never>?
    private var activeFolder: URL?
    private var generation = UUID()
    public init(directory: URL, supervisor: URL) { self.directory = directory; self.supervisor = supervisor }

    public func open(invite: PCLInvite, role: PCLLinkConfiguration.Role, peers: [String], latencyFirst: Bool,
                     binaries: EasyTierRuntime.Binaries, automatic: Bool = false, event: @escaping @Sendable (PCLRoomEvent) -> Void) async throws {
        stop()
        let operation = generation
        try Task.checkCancellation()
        let reservations = LinkPortReservations(excluding: [invite.port]); defer { reservations.release() }
        let rpc = try reservations.reserve(), listener = try reservations.reserve(), local = try reservations.reserve()
        let config = try PCLLinkConfiguration(invite: invite, role: role, peers: peers, rpcPort: rpc, listenerPort: listener,
                                              localPort: local, latencyFirst: latencyFirst, automatic: automatic)
        let shareCode: String
        if automatic && role == .host {
            let hints = PCLLinkDiscovery.directPeers(port: listener)
            shareCode = try PCLRoomLink(invite: invite, peers: Array((hints + peers).prefix(8))).code
        } else { shareCode = invite.code }
        try check(operation)
        guard FileManager.default.isExecutableFile(atPath: supervisor.path) else { throw PCLLinkError.invalid("缺少联机进程管理模块，请使用完整的 Mac 应用构建。") }
        let folder = try LinkSessionStorage.create(in: directory)
        activeFolder = folder
        let file = folder.appendingPathComponent("room.toml")
        do {
            guard FileManager.default.createFile(atPath: file.path, contents: Data(config.toml.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw PCLLinkError.invalid("无法保存联机配置。")
            }
            event(.progress(role == .host ? (automatic ? "正在自动建立房间网络……" : "正在创建房间，连接自定义节点……") : "正在加入房间，查找房主……"))
            let child = LinkProcess(); core = child
            reservations.release()
            try child.start(executable: supervisor, arguments: [binaries.core.path] + config.coreArguments(configFile: file), workingDirectory: folder) { line in
                if line.lowercased().contains("network_secret") { event(.output("[联机凭据字段已隐藏]")) }
                else { event(.output(invite.redacting(line))) }
            }
            nodeMaintenance = Task { await LinkNodeMaintenance.run(cli: binaries.cli, rpc: rpc, peers: config.peers, event: event) }
            let deadline = ProcessInfo.processInfo.systemUptime + 75
            var ready: [PCLLinkPeer]?
            while ProcessInfo.processInfo.systemUptime < deadline {
                try check(operation)
                guard child.isRunning else { throw PCLLinkError.invalid("联机模块已退出，请查看联机日志。") }
                if let list = try? await Self.queryPeers(binaries.cli, port: rpc) {
                    try check(operation)
                    let foundTarget = role == .host
                        ? (automatic ? list.contains(where: { $0.isLocal && $0.isHost }) : list.contains(where: { !$0.isLocal && ($0.latencyMS ?? 0) > 0 }))
                        : list.contains(where: { $0.isHost && !$0.isLocal && ($0.latencyMS ?? 0) > 0 }) && list.contains(where: { $0.isLocal && !$0.ipv4.isEmpty })
                    if foundTarget {
                        if role == .guest { try await LinkTCPProbe.waitForForward(port: local) }
                        ready = list; break
                    }
                }
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            try check(operation)
            guard let ready else { throw PCLLinkError.invalid(role == .host ? "连接自定义节点超时，请检查节点地址、端口及网络。" : (automatic ? "无法与房主建立连接。请确认房间仍开启，连接码完整；双方网络可能阻止直连，或公共发现服务暂时不可用。" : "未找到房主，请确认双方使用同一节点、房主仍在线，且房主使用原版 PCL 02 邀请码。")) }
            // As in the original launcher, let DHCP/routes settle after discovery.
            // Accepting a connection on the local proxy alone does not prove that its
            // remote destination is reachable yet.
            var connectedPeers = ready
            if role == .guest {
                event(.progress("已找到房主，正在等待连接稳定……"))
                try await Task.sleep(nanoseconds: 5_000_000_000)
                try check(operation)
                connectedPeers = try await Self.queryPeers(binaries.cli, port: rpc)
                guard connectedPeers.contains(where: { $0.isHost && !$0.isLocal }),
                      connectedPeers.contains(where: { $0.isLocal && !$0.ipv4.isEmpty }) else {
                    throw PCLLinkError.invalid("房间网络尚未就绪，请检查房主状态后重试。")
                }
                try await LinkTCPProbe.waitForForward(port: local)
                try check(operation)
            }
            if role == .guest { advertisement = try? LinkLANAdvertisement(port: local) }
            event(.connected(Self.snapshot(config, peers: connectedPeers, reconnecting: false, automatic: automatic, shareCode: shareCode)))
            monitor = Task { [weak self] in
                var missed = 0
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        guard let self else { return }
                        let healthy = try await self.poll(operation: operation, config: config, binaries: binaries, automatic: automatic, shareCode: shareCode, event: event)
                        missed = healthy ? 0 : missed + 1
                        if missed >= 10 {
                            await self.endFailed(operation, message: "联机连接已中断，请检查网络或重新加入房间。", event: event); return
                        }
                    } catch is CancellationError { return }
                    catch {
                        guard let self else { return }
                        missed += 1
                        if missed >= 10 {
                            await self.endFailed(operation, message: "联机模块已退出或无法查询状态。", event: event); return
                        }
                        event(.output("联机状态查询暂时不可用，正在重试。"))
                    }
                }
            }
        } catch {
            if generation == operation { stop() }
            throw error
        }
    }
    public func stop() {
        generation = UUID(); monitor?.cancel(); monitor = nil
        nodeMaintenance?.cancel(); nodeMaintenance = nil
        advertisement?.stop(); advertisement = nil
        core?.stop(); core = nil
        if let folder = activeFolder { try? FileManager.default.removeItem(at: folder) }
        activeFolder = nil
    }
    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard operation == generation else { throw CancellationError() }
    }
    private func poll(operation: UUID, config: PCLLinkConfiguration, binaries: EasyTierRuntime.Binaries,
                      automatic: Bool, shareCode: String, event: @escaping @Sendable (PCLRoomEvent) -> Void) async throws -> Bool {
        try check(operation)
        guard core?.isRunning == true else { throw PCLLinkError.invalid("联机模块已退出。") }
        let peers = try await Self.queryPeers(binaries.cli, port: config.rpcPort)
        try check(operation)
        // An automatic host can wait for a direct guest even when all public
        // entry points are unreachable; local readiness is not a NAT success claim.
        let healthy = config.role == .host ? (automatic || peers.contains(where: { !$0.isLocal })) : peers.contains(where: { $0.isHost && !$0.isLocal })
        event(.connected(Self.snapshot(config, peers: peers, reconnecting: !healthy, automatic: automatic, shareCode: shareCode)))
        return healthy
    }
    private func endFailed(_ operation: UUID, message: String, event: @Sendable (PCLRoomEvent) -> Void) {
        guard generation == operation else { return }
        stop(); event(.failed(message))
    }
    static func queryPeers(_ cli: URL, port: UInt16) async throws -> [PCLLinkPeer] {
        try await PCLLinkPeer.parse(LinkCommand.run(cli, ["-p", "127.0.0.1:\(port)", "-o", "json", "peer"]))
    }
    private static func snapshot(_ configuration: PCLLinkConfiguration, peers: [PCLLinkPeer], reconnecting: Bool, automatic: Bool, shareCode: String) -> PCLRoomSnapshot {
        var value = PCLRoomSnapshot(isHost: configuration.role == .host, inviteCode: shareCode, gamePort: configuration.invite.port,
                                   localAddress: configuration.connectionAddress, peers: peers, reconnecting: reconnecting)
        value.automatic = automatic; return value
    }
}

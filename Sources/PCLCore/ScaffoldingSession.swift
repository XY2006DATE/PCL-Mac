import Foundation

public actor ScaffoldingSession {
    private let directory: URL
    private let supervisor: URL
    private var core: LinkProcess?
    private var server: ScaffoldingServer?
    private var advertisement: LinkLANAdvertisement?
    private var monitor: Task<Void, Never>?
    private var nodeMaintenance: Task<Void, Never>?
    private var folder: URL?
    private var generation = UUID()
    private var hostRuntime: (rpc: UInt16, control: UInt16, listener: UInt16, cli: URL)?
    private var hostedPort: UInt16 = 0
    private var guestForward: (remote: UInt16, local: UInt16)?
    private var publishing: UUID?
    public init(directory: URL, supervisor: URL) { self.directory = directory; self.supervisor = supervisor }

    /// A host supplies a fixed port or zero to open a lobby before its game is available. Guests pass nil.
    public func open(invite: ScaffoldingInvite, gamePort: UInt16?, peers: [String], latencyFirst: Bool,
                     playerName: String, machineID: String, binaries: EasyTierRuntime.Binaries,
                     event: @escaping @Sendable (PCLRoomEvent) -> Void) async throws {
        stop(); let operation = generation
        try Task.checkCancellation()
        let isHost = gamePort != nil
        if let gamePort, gamePort != 0, gamePort <= 1024 { throw PCLLinkError.invalid("房主共享端口无效。") }
        try check(operation)
        let nodes = try PCLLinkPeers.parse(peers.joined(separator: ","), maximum: 16)
        let ports = LinkPortReservations(excluding: Set([gamePort ?? 0])); defer { ports.release() }
        let rpc = try ports.reserve(), listener = try ports.reserve(), control = try ports.reserve()
        let name = String(playerName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let profile = ScaffoldingProfile(name: name.isEmpty ? "PCL Mac 玩家" : name, machine_id: machineID, vendor: "PCL Mac / EasyTier \(EasyTierRuntime.version)", kind: isHost ? "HOST" : nil)
        guard FileManager.default.isExecutableFile(atPath: supervisor.path) else { throw PCLLinkError.invalid("缺少联机进程管理模块，请使用完整应用构建。") }
        let folder = try LinkSessionStorage.create(in: directory); self.folder = folder
        do {
            let text = Self.configuration(invite: invite, gamePort: gamePort, control: control, listener: listener, peers: nodes, latencyFirst: latencyFirst, machineID: machineID)
            let file = folder.appendingPathComponent("room.toml")
            guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { throw PCLLinkError.invalid("无法保存联机配置。") }
            ports.release()
            if let gamePort {
                let server = ScaffoldingServer(gamePort: gamePort, host: profile); self.server = server
                try await server.start(port: control); try check(operation)
            }
            event(.progress(isHost ? "正在自动创建大厅……" : "正在自动发现房主并建立直连……"))
            let child = LinkProcess(); core = child
            try child.start(executable: supervisor, arguments: [binaries.core.path, "--config-file", file.path, "--rpc-portal", "127.0.0.1:\(rpc)", "--rpc-portal-whitelist", "127.0.0.1/32", "--disable-env-parsing"] + LinkRuntimeOptions.logging, workingDirectory: folder) { line in
                event(.output(line.lowercased().contains("network_secret") ? "[联机凭据字段已隐藏]" : invite.redacting(line)))
            }
            nodeMaintenance = Task { await LinkNodeMaintenance.run(cli: binaries.cli, rpc: rpc, peers: nodes, rendezvousPeers: PCLLinkDiscovery.scaffoldingRendezvousPeers, event: event) }
            let deadline = ProcessInfo.processInfo.systemUptime + 75
            var initial: [PCLLinkPeer] = [], target: PCLLinkPeer?
            var reportedDiscovery = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                try check(operation)
                guard child.isRunning else { throw PCLLinkError.invalid("联机模块已退出，请查看日志。") }
                if let list = try? await PCLMultiplayerSession.queryPeers(binaries.cli, port: rpc) {
                    try check(operation)
                    if isHost, list.contains(where: { $0.isLocal && $0.ipv4 == "10.114.51.41" }) { initial = list; break }
                    if !isHost, !reportedDiscovery, list.contains(where: { !$0.isLocal }) {
                        reportedDiscovery = true
                        event(.progress("公共发现入口已连通，正在查找房主……"))
                    }
                    let hosts = list.filter { !$0.isLocal && $0.hostname.hasPrefix("scaffolding-mc-server-") }
                    guard hosts.count <= 1 else { throw PCLLinkError.invalid("检测到重复房主，请重新创建大厅。") }
                    if !isHost, let host = hosts.first, list.contains(where: { $0.isLocal && !$0.ipv4.isEmpty }) {
                        initial = list; target = host; break
                    }
                }
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            try check(operation)
            guard !initial.isEmpty else { throw PCLLinkError.invalid(isHost ? "联机模块未能就绪，请查看日志。" : "暂时无法找到房主。请确认大厅码正确、房主仍在线；公共发现服务或当前网络可能暂时不可用。") }
            var profiles = isHost ? [profile] : []
            if let target {
                guard let remoteControl = UInt16(target.hostname.split(separator: "-").last ?? ""), remoteControl > 1024,
                      target.ipv4 == "10.114.51.41" else { throw PCLLinkError.invalid("房主控制端口无效。") }
                event(.progress("已找到房主（\(target.connection)），正在交换大厅信息……"))
                try await Self.forward(cli: binaries.cli, rpc: rpc, proto: "tcp", local: control, remote: remoteControl)
                try await Task.sleep(nanoseconds: 5_000_000_000); try check(operation)
                var result: Data?
                for _ in 0..<5 {
                    do { result = try await ScaffoldingRPC.call(port: control, type: "c:server_port"); break }
                    catch { try check(operation); try await Task.sleep(nanoseconds: 700_000_000) }
                }
                guard let result, result.count == 2 else { throw PCLLinkError.invalid("已发现房主，但未能完成大厅控制连接。部分 PCL CE 构建仅允许直连；连接公共节点并不代表双方已打洞成功。请保持房间开启后重新加入。") }
                let remotePort = try Self.decodeGamePort(result)
                profiles = try await Self.heartbeat(port: control, profile: profile)
                try check(operation)
                if remotePort != 0 {
                    try await prepareForward(to: remotePort, cli: binaries.cli, rpc: rpc, control: control, operation: operation)
                }
            }
            try check(operation)
            if let gamePort {
                hostRuntime = (rpc, control, listener, binaries.cli)
                hostedPort = gamePort
            }
            event(.connected(snapshot(invite: invite, isHost: isHost, peers: initial, names: profiles.map(\.name), reconnecting: false)))
            monitor = Task { [weak self] in
                var missed = 0
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        guard let self else { return }
                        let healthy = try await self.poll(operation: operation, invite: invite, isHost: isHost, control: control, rpc: rpc, profile: profile, binaries: binaries, event: event)
                        missed = healthy ? 0 : missed + 1
                    } catch is CancellationError { return }
                    catch { missed += 1 }
                    if missed >= 8 {
                        guard let self else { return }; await self.end(operation, event: event); return
                    }
                }
            }
        } catch { if operation == generation { stop() }; throw error }
    }
    public func publishGamePort(_ port: UInt16) async throws {
        guard let hostRuntime, let server, core?.isRunning == true else {
            throw PCLLinkError.invalid("房主大厅尚未就绪。")
        }
        guard port > 1024, ![hostRuntime.rpc, hostRuntime.control, hostRuntime.listener].contains(port) else {
            throw PCLLinkError.invalid("此端口不能用于共享游戏。")
        }
        guard hostedPort == 0, publishing == nil else { throw PCLLinkError.invalid("此大厅已设置共享端口。") }
        let operation = generation
        publishing = operation
        defer { if publishing == operation { publishing = nil } }
        try await LinkTCPProbe.requireGame(port: port)
        try check(operation)
        let args = ["-p", "127.0.0.1:\(hostRuntime.rpc)", "whitelist"]
        let current = String(hostRuntime.control)
        let shared = "\(port),\(current)"
        do {
            _ = try await LinkCommand.run(hostRuntime.cli, args + ["set-udp", shared], timeout: 10)
            try check(operation)
            _ = try await LinkCommand.run(hostRuntime.cli, args + ["set-tcp", shared], timeout: 10)
            try check(operation)
        } catch {
            if generation == operation {
                // Keep the control channel reachable if either update failed.
                let cli = hostRuntime.cli
                await Task.detached {
                    for proto in ["tcp", "udp"] {
                        _ = try? await LinkCommand.run(cli, args + ["set-\(proto)", current], timeout: 5)
                    }
                }.value
            }
            throw error
        }
        server.publishGamePort(port)
        hostedPort = port
    }

    public func stop() {
        generation = UUID(); monitor?.cancel(); monitor = nil
        hostRuntime = nil; hostedPort = 0; guestForward = nil; publishing = nil
        nodeMaintenance?.cancel(); nodeMaintenance = nil
        advertisement?.stop(); advertisement = nil; server?.stop(); server = nil; core?.stop(); core = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil
    }
    private func check(_ operation: UUID) throws { try Task.checkCancellation(); guard generation == operation else { throw CancellationError() } }
    private func end(_ operation: UUID, event: @Sendable (PCLRoomEvent) -> Void) {
        guard generation == operation else { return }; stop(); event(.failed("大厅连接已中断，请检查网络后重新加入。"))
    }
    private func poll(operation: UUID, invite: ScaffoldingInvite, isHost: Bool, control: UInt16, rpc: UInt16,
                      profile: ScaffoldingProfile, binaries: EasyTierRuntime.Binaries, event: @Sendable (PCLRoomEvent) -> Void) async throws -> Bool {
        try check(operation); guard core?.isRunning == true else { throw PCLLinkError.invalid("联机模块已退出。") }
        let peers = try await PCLMultiplayerSession.queryPeers(binaries.cli, port: rpc)
        let profiles: [ScaffoldingProfile]
        if isHost {
            profiles = try JSONDecoder().decode([ScaffoldingProfile].self, from: await ScaffoldingRPC.call(port: control, type: "c:player_profiles_list"))
        } else { profiles = try await Self.heartbeat(port: control, profile: profile) }
        try check(operation)
        let healthy = isHost || peers.contains(where: { !$0.isLocal && $0.hostname.hasPrefix("scaffolding-mc-server-") })
        if !isHost, healthy, guestForward == nil {
            let port = try Self.decodeGamePort(await ScaffoldingRPC.call(port: control, type: "c:server_port"))
            try check(operation)
            if port != 0 { try await prepareForward(to: port, cli: binaries.cli, rpc: rpc, control: control, operation: operation) }
        }
        event(.connected(snapshot(invite: invite, isHost: isHost, peers: peers, names: profiles.map(\.name), reconnecting: !healthy)))
        return healthy
    }
    private static func heartbeat(port: UInt16, profile: ScaffoldingProfile) async throws -> [ScaffoldingProfile] {
        _ = try await ScaffoldingRPC.call(port: port, type: "c:player_ping", body: JSONEncoder().encode(profile))
        let bytes = try await ScaffoldingRPC.call(port: port, type: "c:player_profiles_list")
        let profiles = try JSONDecoder().decode([ScaffoldingProfile].self, from: bytes)
        guard profiles.count <= 65, profiles.allSatisfy({ $0.name.count <= 64 && $0.machine_id.count <= 128 && $0.vendor.count <= 128 }) else { throw PCLLinkError.invalid("房间成员列表无效。") }
        return profiles
    }
    private static func forward(cli: URL, rpc: UInt16, proto: String, local: UInt16, remote: UInt16) async throws {
        _ = try await LinkCommand.run(cli, ["-p", "127.0.0.1:\(rpc)", "port-forward", "add", proto, "127.0.0.1:\(local)", "10.114.51.41:\(remote)"], timeout: 15)
    }
    private static func decodeGamePort(_ bytes: Data) throws -> UInt16 {
        guard bytes.count == 2 else { throw PCLLinkError.invalid("房主共享端口响应无效。") }
        let port = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard port == 0 || port > 1024 else { throw PCLLinkError.invalid("房主共享端口无效。") }
        return port
    }

    private func prepareForward(to port: UInt16, cli: URL, rpc: UInt16, control: UInt16, operation: UUID) async throws {
        let reservations = LinkPortReservations(excluding: [port, rpc, control])
        let local = try reservations.reserve()
        reservations.release()
        do {
            for proto in ["tcp", "udp"] {
                try await Self.forward(cli: cli, rpc: rpc, proto: proto, local: local, remote: port)
                try check(operation)
            }
            try await LinkTCPProbe.waitForForward(port: local)
            try check(operation)
        } catch {
            if generation == operation {
                for proto in ["tcp", "udp"] {
                    _ = try? await LinkCommand.run(cli, ["-p", "127.0.0.1:\(rpc)", "port-forward", "remove", proto,
                                                        "127.0.0.1:\(local)", "10.114.51.41:\(port)"], timeout: 5)
                }
            }
            throw error
        }
        guestForward = (port, local)
        advertisement = try? LinkLANAdvertisement(port: local)
    }

    private func snapshot(invite: ScaffoldingInvite, isHost: Bool, peers: [PCLLinkPeer], names: [String], reconnecting: Bool) -> PCLRoomSnapshot {
        let gamePort = isHost ? hostedPort : (guestForward?.remote ?? 0)
        let address = guestForward.map { "127.0.0.1:\($0.local)" } ?? ""
        var value = PCLRoomSnapshot(isHost: isHost, inviteCode: invite.code, gamePort: gamePort, localAddress: address, peers: peers, reconnecting: reconnecting)
        value.automatic = true; value.scaffolding = true; value.playerNames = names; return value
    }
    static func configuration(invite: ScaffoldingInvite, gamePort: UInt16?, control: UInt16, listener: UInt16, peers: [String], latencyFirst: Bool, machineID: String) -> String {
        func quote(_ value: String) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(data: try! encoder.encode(value), encoding: .utf8)!
        }
        let host = gamePort != nil
        let allowed = gamePort.map { $0 == 0 ? "[\"\(control)\"]" : "[\"\($0)\", \"\(control)\"]" } ?? "[\"0\"]"
        var text = """
        instance_name = "pcl-mac-scaffolding"
        hostname = \(quote(host ? "scaffolding-mc-server-\(control)" : machineID))
        \(host ? "ipv4 = \"10.114.51.41\"" : "")
        dhcp = \(!host)
        listeners = ["tcp://0.0.0.0:\(listener)", "udp://0.0.0.0:\(listener)"]
        tcp_whitelist = \(allowed)
        udp_whitelist = \(allowed)
        [network_identity]
        network_name = \(quote(invite.networkName))
        network_secret = \(quote(invite.networkSecret))
        [flags]
        no_tun = true
        use_smoltcp = true
        bind_device = false
        enable_ipv6 = true
        enable_encryption = true
        encryption_algorithm = "aes-gcm"
        compression = "zstd"
        private_mode = true
        latency_first = \(latencyFirst)
        relay_network_whitelist = ""
        accept_dns = false
        enable_exit_node = false
        """
        for peer in peers { text += "\n[[peer]]\nuri = \(quote(peer))\n" }
        return text + "\n"
    }
}

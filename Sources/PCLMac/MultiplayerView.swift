import AppKit
import Combine
import PCLCore
import SwiftUI

@MainActor final class MultiplayerState: ObservableObject {
    enum Phase { case idle, preparing, connecting, connected, failed }
    enum RoomProtocol: String, CaseIterable { case automatic = "自动联机（CE / HMCL）", direct = "Mac 直连（IPv6 / 局域网）", original = "原版 PCL 自定义节点" }
    @Published var roomProtocol: RoomProtocol = .automatic
    @Published var phase: Phase = .idle
    @Published var message = "准备就绪"
    @Published var failure: String?
    @Published var snapshot: PCLRoomSnapshot?
    @Published var portText = ""
    @Published var inviteText = ""
    @Published var logs: [String] = []
    private var logBuffer = LinkLogBuffer()
    @Published var customPeers = UserDefaults.standard.string(forKey: "PCLSwiftUI.link.peers.v1") ?? "" {
        didSet { UserDefaults.standard.set(customPeers, forKey: "PCLSwiftUI.link.peers.v1") }
    }
    @Published var latencyFirst = UserDefaults.standard.bool(forKey: "PCLSwiftUI.link.latencyFirst.v1") {
        didSet { UserDefaults.standard.set(latencyFirst, forKey: "PCLSwiftUI.link.latencyFirst.v1") }
    }
    private var task: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var operation = UUID()
    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PCL-SwiftUI/Multiplayer") }
    private let runtime = EasyTierRuntime(directory: support.appendingPathComponent("Runtime"))
    private let discovery = PCLLinkDiscovery(cache: support.appendingPathComponent("public-nodes.json"))
    private let session = PCLMultiplayerSession(directory: support.appendingPathComponent("Sessions"),
                                                supervisor: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PCLLinkSupervisor"))
    private let scaffolding = ScaffoldingSession(directory: support.appendingPathComponent("Sessions"),
                                                supervisor: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PCLLinkSupervisor"))
    private let machineID = UUID().uuidString
    var isActive: Bool { phase == .preparing || phase == .connecting || phase == .connected }
    var pending: Bool { phase == .preparing || phase == .connecting }
    func create(playerName: String = "PCL Mac 玩家") {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port > 1024 else {
            failure = "请先在 Minecraft 中对局域网开放，并填写 1025–65535 之间的端口。"; return
        }
        if roomProtocol == .automatic { beginScaffolding(invite: .create(), port: port, playerName: playerName); return }
        if roomProtocol == .original && customPeers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failure = "原版 PCL 兼容模式需要共同的自定义节点。无需填写节点的联机请选择默认自动模式。"; return
        }
        do { begin(invite: try PCLInvite.create(port: port), role: .host) } catch { failure = error.localizedDescription }
    }
    func join(playerName: String = "PCL Mac 玩家") {
        do {
            if inviteText.uppercased().contains("U/") {
                beginScaffolding(invite: try ScaffoldingInvite(inviteText), port: nil, playerName: playerName)
            } else if inviteText.contains(PCLRoomLink.prefix) {
                let link = try PCLRoomLink(inviteText); begin(invite: link.invite, role: .guest, advertisedPeers: link.peers)
            } else {
                let invite = try PCLInvite(inviteText); try invite.requireCustomNode()
                guard !customPeers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failure = "这是原版 PCL 自定义节点邀请码，需要双方使用同一节点。无需填写节点的跨启动器联机，请让房主创建 U/ 自动大厅。"; return
                }
                begin(invite: invite, role: .guest)
            }
        }
        catch { failure = error.localizedDescription }
    }
    private func beginScaffolding(invite: ScaffoldingInvite, port: UInt16?, playerName: String) {
        guard !isActive else { return }
        let custom = customPeers.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured: [String]?
        do { configured = custom.isEmpty ? nil : try PCLLinkPeers.parse(custom) } catch { failure = error.localizedDescription; return }
        let id = UUID(); operation = id; failure = nil; snapshot = nil; logs = []; logBuffer = LinkLogBuffer(); phase = .preparing; message = "自动准备联机环境"
        let latency = latencyFirst
        task = Task { [self] in
            do {
                await cleanup?.value; try Task.checkCancellation()
                if let port { try await LinkTCPProbe.requireGame(port: port) }
                let peers: [String]
                if let configured { peers = configured } else { peers = try PCLLinkDiscovery.scaffoldingPeers(await discovery.resolve()) }
                let binaries = try await runtime.prepare { [weak self] progress in
                    Task { @MainActor in guard let self, self.operation == id else { return }; self.message = progress }
                }
                try Task.checkCancellation(); guard operation == id else { return }; phase = .connecting
                try await scaffolding.open(invite: invite, gamePort: port, peers: peers, latencyFirst: latency, playerName: playerName, machineID: machineID, binaries: binaries) { [weak self] event in
                    Task { @MainActor in guard let self, self.operation == id else { return }; self.receive(event) }
                }
            } catch is CancellationError { if operation == id { phase = .idle; message = "已取消联机" } }
            catch { if operation == id { phase = .failed; failure = invite.redacting(error.localizedDescription); logBuffer.append(failure ?? "联机失败"); logs = logBuffer.lines; message = "联机失败" } }
            if operation == id { task = nil }
        }
    }
    private func begin(invite: PCLInvite, role: PCLLinkConfiguration.Role, advertisedPeers: [String]? = nil) {
        guard !isActive else { return }
        let custom = customPeers.trimmingCharacters(in: .whitespacesAndNewlines)
        let automatic = advertisedPeers != nil || custom.isEmpty || (role == .host && roomProtocol == .direct)
        let configured: [String]?
        do { configured = try advertisedPeers ?? (custom.isEmpty ? nil : PCLLinkPeers.parse(custom)) } catch { failure = error.localizedDescription; return }
        let id = UUID(); operation = id; failure = nil; snapshot = nil; logs = []; logBuffer = LinkLogBuffer()
        phase = .preparing; message = "检查联机环境"
        let latency = latencyFirst
        task = Task { [self] in
            do {
                await cleanup?.value; try Task.checkCancellation()
                if role == .host { try await LinkTCPProbe.requireGame(port: invite.port) }
                let peers: [String]
                if let configured { peers = configured }
                else {
                    message = "自动查找公共发现入口……"
                    peers = try await discovery.resolve()
                    try Task.checkCancellation()
                }
                let binaries = try await runtime.prepare { [weak self] progress in
                    Task { @MainActor in guard let self, self.operation == id else { return }; self.message = progress }
                }
                try Task.checkCancellation()
                guard operation == id else { return }
                phase = .connecting
                try await session.open(invite: invite, role: role, peers: peers, latencyFirst: latency, binaries: binaries, automatic: automatic) { [weak self] event in
                    Task { @MainActor in guard let self, self.operation == id else { return }; self.receive(event) }
                }
            } catch is CancellationError {
                if operation == id { phase = .idle; message = "已取消联机" }
            } catch {
                if operation == id { phase = .failed; failure = invite.redacting(error.localizedDescription); logBuffer.append(failure ?? "联机失败"); logs = logBuffer.lines; message = "联机失败" }
            }
            if operation == id { task = nil }
        }
    }
    private func receive(_ event: PCLRoomEvent) {
        switch event {
        case .progress(let text):
            if message != text { logBuffer.append(text); logs = logBuffer.lines }; message = text
        case .output(let text):
            if !text.isEmpty { logBuffer.append(text); logs = logBuffer.lines }
        case .connected(let value):
            snapshot = value; phase = .connected
            message = value.reconnecting ? "连接恢复中" : (value.isHost ? (value.automatic && value.playerCount < 2 ? "房间已就绪，等待朋友加入" : "已创建房间") : "已加入房间")
        case .failed(let text):
            logBuffer.append(text); logs = logBuffer.lines
            failure = text; phase = .failed; snapshot = nil; message = "联机已结束"
        }
    }
    func stop() {
        if isActive { logBuffer.append("已主动退出或取消联机。"); logs = logBuffer.lines }
        operation = UUID(); task?.cancel(); task = nil
        snapshot = nil; phase = .idle; message = "已退出联机"; failure = nil
        cleanup = Task { await session.stop(); await scaffolding.stop() }
    }
    func requestLeave() {
        guard phase == .connected else { stop(); return }
        let alert = NSAlert(); alert.messageText = snapshot?.isHost == true ? "关闭联机房间？" : "离开联机房间？"
        alert.informativeText = snapshot?.isHost == true ? "房间中的朋友会断开连接，再次创建会生成新的邀请码。" : "将停止此房间的本机端口转发。"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { stop() }
    }
}

struct MultiplayerView: View {
    @EnvironmentObject private var store: LauncherStore
    @ObservedObject var model: MultiplayerState
    var body: some View {
        Group {
            if let failure = model.failure { PCLHint(text: failure, warning: true) }
            if model.pending {
                PCLCard(title: model.phase == .preparing ? "准备联机模块" : "正在连接房间") {
                    HStack(spacing: 20) {
                        ProgressView().controlSize(.large)
                        Text(model.message).font(.custom("PCL English", size: 14))
                        Spacer()
                        Button("取消") { model.stop() }.buttonStyle(PCLActionStyle())
                    }.padding(.vertical, 20)
                }
            } else if let room = model.snapshot, model.phase == .connected {
                PCLCard(title: model.message) {
                    VStack(alignment: .leading, spacing: 18) {
                        if room.isHost {
                            Text("把邀请码发给朋友，让大家加入房间吧！").foregroundStyle(.secondary)
                            Text(room.inviteCode).font(.system(size: room.automatic && !room.scaffolding ? 12 : 22, design: .monospaced)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Button(room.scaffolding ? "复制大厅码" : "复制连接码") {
                                NSPasteboard.general.clearContents()
                                let launcher = room.scaffolding ? "PCL Mac版、PCL CE 或 HMCL" : (room.automatic ? "PCL Mac版" : "PCL 启动器")
                                NSPasteboard.general.setString(room.scaffolding ? room.inviteCode : "在 \(launcher) 中输入连接码【\(room.inviteCode)】，即可加入联机房间！", forType: .string)
                            }.buttonStyle(PCLActionStyle(highlight: true))
                            Text("房主游戏端口：\(String(room.gamePort))")
                            if room.automatic {
                                Text(room.scaffolding ? "Windows 朋友可在 PCL CE、HMCL 等支持 Scaffolding 的启动器中输入大厅码。原版 PCL 使用另一套协议。" : "Mac 直连码供 Mac 版使用；原版 PCL 邀请码与 CE 大厅码属于其他联机模式。")
                                    .font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                                if !room.peers.contains(where: { !$0.isLocal }) {
                                    PCLHint(text: room.scaffolding ? "公共发现入口尚未连通，正在后台重试。大厅码已生成，但当前还不能确认朋友能够发现此大厅。" : "公共发现入口尚未连通，正在后台重试；同一局域网或可达 IPv6 的朋友仍可通过连接码尝试直连。", warning: true)
                                }
                            }
                        } else {
                            Text("进入 Minecraft 的多人游戏页面查找 PCL 联机房间，也可使用下方地址直接连接。")
                            HStack {
                                Text(room.localAddress).font(.system(size: 18, design: .monospaced)).textSelection(.enabled)
                                Button("复制连接地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(room.localAddress, forType: .string) }.buttonStyle(PCLActionStyle())
                            }
                        }
                        HStack { Text("\(room.playerCount) 人"); Spacer(); Button(room.isHost ? "关闭房间" : "离开房间") { model.requestLeave() }.buttonStyle(PCLActionStyle()) }
                    }.font(.custom("PCL English", size: 13))
                }
                PCLCard(title: "连接状态") {
                    VStack(spacing: 12) {
                        ForEach(Array(room.peers.enumerated()), id: \.offset) { _, peer in
                            HStack {
                                PCLIcon("Online").frame(width: 17, height: 17)
                                Text(peer.isHost ? "房主" : (peer.isLocal ? store.preferences.playerName : (UUID(uuidString: peer.hostname) != nil ? "玩家" : (peer.hostname.hasPrefix("PublicServer") ? "公共节点 · " + peer.hostname : peer.hostname)))).lineLimit(1)
                                Spacer(); Text(peer.connection)
                                Text(peer.latencyMS.map { String(format: "%.1f ms", $0) } ?? "—").frame(width: 85, alignment: .trailing)
                            }.font(.custom("PCL English", size: 12))
                        }
                    }
                }
                if !room.playerNames.isEmpty {
                    PCLCard(title: "大厅成员") { Text(room.playerNames.joined(separator: "、")).font(.custom("PCL English", size: 13)) }
                }
            } else {
                PCLCard(title: "创建房间") {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(spacing: 20) {
                            PCLIcon("RoomCreate").frame(width: 40, height: 40).foregroundStyle(ClassicTheme.blue)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("邀请朋友加入你的单人游戏。").font(.custom("PCL English", size: 15))
                                Text("先启动 Minecraft 并进入单人世界，点击“对局域网开放”，再填写聊天中显示的端口，并保持世界运行。").foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Text("游戏端口").frame(width: 85, alignment: .leading)
                            TextField("游戏内开放后提示的端口", text: $model.portText).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                            Button("创建房间") { model.create(playerName: store.preferences.playerName) }.buttonStyle(PCLActionStyle(highlight: true))
                        }
                    }.padding(.vertical, 15)
                }
                PCLCard(title: "加入房间") {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(spacing: 20) {
                            PCLIcon("RoomJoin").frame(width: 40, height: 40).foregroundStyle(ClassicTheme.blue)
                            Text("输入朋友发来的大厅码、Mac 直连码或原版 PCL 邀请码。").font(.custom("PCL English", size: 15))
                        }
                        HStack {
                            TextField("粘贴完整连接码", text: $model.inviteText).textFieldStyle(.roundedBorder)
                            Button("加入房间") { model.join(playerName: store.preferences.playerName) }.buttonStyle(PCLActionStyle(highlight: true))
                        }
                    }.padding(.vertical, 15)
                }
                PCLCard(title: "连接选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("默认自动发现并尝试 IPv6／IPv4 点对点连接，无需搭建服务器或填写节点。无法直连时由可用公共节点中继，具体取决于双方网络。")
                        Button("联机设置") { store.settingsTab = "联机"; store.page = .settings }.buttonStyle(PCLActionStyle())
                    }.font(.custom("PCL English", size: 13))
                }
            }
            if !model.logs.isEmpty {
                PCLCard(title: "联机日志", collapsible: true, expanded: false) {
                    Text("仅保留最近 200 条、最多 64 KB；重复日志自动合并，不写入磁盘。")
                        .font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                    ScrollView([.horizontal, .vertical]) {
                        Text(model.logs.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }.frame(height: 180)
                }
            }
        }
    }
}

struct MultiplayerSettingsView: View {
    @ObservedObject var model: MultiplayerState
    var body: some View {
        Group {
            PCLCard(title: "连接选项") {
                HStack(spacing: 20) {
                    Text("创建模式").frame(width: 110, alignment: .leading)
                    PCLComboBox(title: "创建模式", selection: $model.roomProtocol, options: MultiplayerState.RoomProtocol.allCases.map { .init(title: $0.rawValue, value: $0) }).frame(height: 28)
                }
                HStack(spacing: 20) {
                    Text("模式").frame(width: 110, alignment: .leading)
                    PCLComboBox(title: "模式", selection: $model.latencyFirst, options: [.init(title: "优先直连", value: false), .init(title: "优先低延迟", value: true)]).frame(height: 28)
                }
            }
            PCLCard(title: "高级设置") {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top, spacing: 20) {
                        Text("自定义节点").frame(width: 110, alignment: .leading).padding(.top, 5)
                        TextField("留空自动选择，无需填写", text: $model.customPeers, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    }
                    Text("通常保持留空。程序自动获取公共节点并尝试直连；仅在需要兼容原版 PCL 自定义节点房间时填写，多个地址使用逗号分隔。")
                        .foregroundStyle(.secondary)
                    Text("修改连接选项将在下一次创建或加入房间时生效。首次使用会从 EasyTier 官方 Release 下载并校验联机模块。")
                        .font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                }
            }
        }.font(.custom("PCL English", size: 13)).disabled(model.isActive)
    }
}

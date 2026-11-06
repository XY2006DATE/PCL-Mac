import AppKit
import Combine
import PCLCore
import SwiftUI

@MainActor final class MultiplayerState: ObservableObject {
    enum Phase { case idle, preparing, connecting, connected, failed }
    enum Section: String, CaseIterable {
        case create = "创建房间"
        case join = "加入房间"
        case options = "连接选项"

        var icon: String {
            switch self {
            case .create: return "RoomCreate"
            case .join: return "RoomJoin"
            case .options: return "SetupOther"
            }
        }
    }
    enum RoomProtocol: String, CaseIterable {
        case automatic = "自动联机（CE / HMCL）"
        case direct = "Mac 直连（IPv6 / 局域网）"
        case original = "原版 PCL 自定义节点"

        var connectionHint: String {
            switch self {
            case .automatic:
                return "自动发现公共入口并尝试 IPv6／IPv4 点对点连接。无法直连时由可用公共节点中继。"
            case .direct:
                return "生成供 PCL Mac 版使用的直连码。同一局域网或双方的 IPv6 网络可达时，可以直接连接。"
            case .original:
                return "使用原版 PCL 的自定义节点邀请码。房主和来宾需填写同一个自定义节点。"
            }
        }
    }
    @Published private(set) var section: Section = .create
    @Published var roomProtocol: RoomProtocol = .automatic
    @Published var phase: Phase = .idle
    @Published var message = "准备就绪"
    @Published var failure: String?
    @Published var snapshot: PCLRoomSnapshot?
    @Published var portText = ""
    @Published private(set) var publishingPort = false
    private var detectedGamePort: UInt16?
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

    func selectSection(_ section: Section) {
        guard !isActive, self.section != section else { return }
        self.section = section
        failure = nil
    }

    func create(playerName: String = "PCL Mac 玩家") {
        let text = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        if roomProtocol == .automatic, text.isEmpty {
            beginScaffolding(invite: .create(), port: 0, playerName: playerName)
            return
        }
        guard let port = UInt16(text), port > 1024 else {
            failure = "请填写要共享的本机端口，范围为 1025–65535。"; return
        }
        if roomProtocol == .automatic { beginScaffolding(invite: .create(), port: port, playerName: playerName); return }
        if roomProtocol == .original && customPeers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failure = "原版 PCL 兼容模式需要共同的自定义节点。无需填写节点的联机请选择默认自动模式。"; return
        }
        do { begin(invite: try PCLInvite.create(port: port), role: .host) } catch { failure = error.localizedDescription }
    }
    func join(playerName: String = "PCL Mac 玩家") {
        guard !isActive else { return }
        do {
            if inviteText.uppercased().contains("U/") {
                let invite = try ScaffoldingInvite(inviteText)
                beginScaffolding(invite: invite, port: nil, playerName: playerName)
            } else if inviteText.contains(PCLRoomLink.prefix) {
                let link = try PCLRoomLink(inviteText)
                begin(invite: link.invite, role: .guest, advertisedPeers: link.peers)
            } else {
                let invite = try PCLInvite(inviteText); try invite.requireCustomNode()
                guard !customPeers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failure = "这是原版 PCL 自定义节点邀请码，需要双方使用同一节点。无需填写节点的跨启动器联机，请让房主创建 U/ 自动大厅。"; return
                }
                begin(invite: invite, role: .guest)
            }
        } catch { failure = error.localizedDescription }
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
    func observeGameOutput(_ output: String) {
        guard let port = MinecraftLauncher.openedLANPort(in: output) else { return }
        detectedGamePort = port
        publishDetectedPortIfReady()
    }

    func gameExited() { detectedGamePort = nil }

    func publishEnteredPort() {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port > 1024 else {
            failure = "请填写本次游戏显示的端口（1025–65535）。"
            return
        }
        publishPort(port)
    }

    private var canPublishPort: Bool {
        snapshot?.isHost == true && snapshot?.scaffolding == true && snapshot?.gamePort == 0 && !publishingPort
    }

    private func publishDetectedPortIfReady() {
        guard canPublishPort, let port = detectedGamePort else { return }
        detectedGamePort = nil
        publishPort(port)
    }

    private func publishPort(_ port: UInt16) {
        guard canPublishPort else { return }
        let id = operation
        publishingPort = true
        failure = nil
        Task {
            do { try await scaffolding.publishGamePort(port) }
            catch {
                guard operation == id else { return }
                publishingPort = false
                if !(error is CancellationError) { failure = error.localizedDescription }
            }
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
            if value.gamePort != 0 { publishingPort = false }
            message = value.reconnecting ? "连接恢复中" : (value.isHost ? (value.automatic && value.playerCount < 2 ? "房间已就绪，等待朋友加入" : "已创建房间") : "已加入房间")
            publishDetectedPortIfReady()
        case .failed(let text):
            logBuffer.append(text); logs = logBuffer.lines
            failure = text; phase = .failed; snapshot = nil; publishingPort = false; message = "联机已结束"
        }
    }
    func stop() {
        if isActive { logBuffer.append("已主动退出或取消联机。"); logs = logBuffer.lines }
        operation = UUID(); task?.cancel(); task = nil; publishingPort = false
        snapshot = nil; phase = .idle; message = "已退出联机"; failure = nil
        cleanup = Task { await session.stop(); await scaffolding.stop() }
    }
    func requestLeave(locale: Locale) {
        guard phase == .connected else { stop(); return }
        let alert = NSAlert(); alert.messageText = InterfaceLanguage.text(snapshot?.isHost == true ? "关闭联机房间？" : "离开联机房间？", locale: locale)
        alert.informativeText = InterfaceLanguage.text(snapshot?.isHost == true ? "房间中的朋友会断开连接，再次创建会生成新的邀请码。" : "将停止此房间的本机端口转发。", locale: locale)
        alert.addButton(withTitle: InterfaceLanguage.text("确定", locale: locale)); alert.addButton(withTitle: InterfaceLanguage.text("取消", locale: locale))
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
                        Text(store.text(model.message)).font(.custom("PCL English", size: 14))
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
                            Button(store.text(room.scaffolding ? "复制大厅码" : "复制连接码")) {
                                NSPasteboard.general.clearContents()
                                let launcher = room.scaffolding ? "PCL Mac版、PCL CE 或 HMCL" : (room.automatic ? "PCL Mac版" : "PCL 启动器")
                                NSPasteboard.general.setString(room.scaffolding ? room.inviteCode : "在 \(launcher) 中输入连接码【\(room.inviteCode)】，即可加入联机房间！", forType: .string)
                            }.buttonStyle(PCLActionStyle(highlight: true))
                            if room.gamePort == 0 {
                                Text("朋友可以先加入。用本启动器启动 Minecraft，在单人世界中选择“对局域网开放”，启动器会尝试自动识别端口。").foregroundStyle(.secondary)
                                HStack {
                                    TextField("也可填写游戏显示的端口", text: $model.portText).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                                    Button(store.text(model.publishingPort ? "正在共享…" : "共享游戏")) { model.publishEnteredPort() }
                                        .buttonStyle(PCLActionStyle()).disabled(model.publishingPort)
                                }
                            } else {
                                Text("共享端口：\(String(room.gamePort))")
                                Text("请让 Minecraft 世界或服务器在此端口监听，朋友就能通过转发地址访问。").foregroundStyle(.secondary)
                            }
                            if room.automatic {
                                Text(room.scaffolding ? (room.gamePort == 0 ? "使用 PCL CE 或 HMCL 的朋友可等游戏已共享后再加入。" : "Windows 朋友可在 PCL CE、HMCL 等支持 Scaffolding 的启动器中输入大厅码。") : "Mac 直连码供 Mac 版使用；原版 PCL 邀请码与 CE 大厅码属于其他联机模式。")
                                    .font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                                if !room.peers.contains(where: { !$0.isLocal }) {
                                    PCLHint(text: room.scaffolding ? "公共发现入口尚未连通，正在后台重试。大厅码已生成，但当前还不能确认朋友能够发现此大厅。" : "公共发现入口尚未连通，正在后台重试；同一局域网或可达 IPv6 的朋友仍可通过连接码尝试直连。", warning: true)
                                }
                            }
                        } else if room.localAddress.isEmpty {
                            Text("房间已连接，正在等待房主共享世界。连接地址会自动出现。").foregroundStyle(.secondary)
                        } else {
                            Text("房主开放世界或启动服务端后，可在 Minecraft 多人游戏中查找房间，或使用下方地址直接连接。")
                            HStack {
                                Text(room.localAddress).font(.system(size: 18, design: .monospaced)).textSelection(.enabled)
                                Button("复制连接地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(room.localAddress, forType: .string) }.buttonStyle(PCLActionStyle())
                            }
                        }
                        HStack { Text("\(room.playerCount) 人"); Spacer(); Button(store.text(room.isHost ? "关闭房间" : "离开房间")) { model.requestLeave(locale: store.interfaceLocale) }.buttonStyle(PCLActionStyle()) }
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
                switch model.section {
                case .create: createRoom
                case .join: joinRoom
                case .options: MultiplayerSettingsView(model: model)
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
    private var createRoom: some View {
        PCLCard(title: "创建房间") {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 20) {
                    PCLIcon("RoomCreate").frame(width: 40, height: 40).foregroundStyle(ClassicTheme.blue)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("建立房间网络并邀请朋友。").font(.custom("PCL English", size: 15))
                        Text(model.roomProtocol == .automatic
                            ? "可以留空直接建房。朋友加入后，再打开 Minecraft 的局域网世界。仅向受信任的朋友分享连接码。"
                            : "请填写游戏显示的端口，或先填写固定端口，再用同一端口开放世界。仅向受信任的朋友分享连接码。").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(store.text(model.roomProtocol == .automatic ? "端口（可选）" : "共享端口")).frame(width: 85, alignment: .leading)
                    TextField(store.text(model.roomProtocol == .automatic ? "留空先建房" : "例如 25565"), text: $model.portText).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Button("创建房间") { model.create(playerName: store.preferences.playerName) }.buttonStyle(PCLActionStyle(highlight: true))
                }
            }.padding(.vertical, 15)
        }
    }

    private var joinRoom: some View {
        PCLCard(title: "加入房间") {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 20) {
                    PCLIcon("RoomJoin").frame(width: 40, height: 40).foregroundStyle(ClassicTheme.blue)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("输入朋友发来的大厅码、Mac 直连码或原版 PCL 邀请码。").font(.custom("PCL English", size: 15))
                        Text("可以在 Minecraft 未安装或未运行时加入，准备好后再打开游戏。").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("粘贴完整连接码", text: $model.inviteText).textFieldStyle(.roundedBorder)
                    Button("加入房间") { model.join(playerName: store.preferences.playerName) }.buttonStyle(PCLActionStyle(highlight: true))
                }
            }.padding(.vertical, 15)
        }
    }

}

struct MultiplayerSettingsView: View {
    @ObservedObject var model: MultiplayerState
    @Environment(\.locale) private var locale
    var body: some View {
        Group {
            PCLCard(title: "连接选项") {
                HStack(spacing: 20) {
                    Text("创建模式").frame(width: 110, alignment: .leading)
                    PCLComboBox(title: "创建模式", selection: $model.roomProtocol,
                        options: MultiplayerState.RoomProtocol.allCases.map { .init(title: $0.rawValue, value: $0) }).frame(height: 28)
                }
                Text(InterfaceLanguage.text(model.roomProtocol.connectionHint, locale: locale)).foregroundStyle(.secondary)
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

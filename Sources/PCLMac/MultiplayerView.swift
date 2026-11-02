import AppKit
import Combine
import PCLCore
import SwiftUI

@MainActor final class MultiplayerState: ObservableObject {
    enum Phase { case idle, preparing, connecting, connected, failed }
    @Published var phase: Phase = .idle
    @Published var message = "准备就绪"
    @Published var failure: String?
    @Published var snapshot: PCLRoomSnapshot?
    @Published var portText = ""
    @Published var inviteText = ""
    @Published var logs: [String] = []
    @Published var customPeers = UserDefaults.standard.string(forKey: "PCLSwiftUI.link.peers.v1") ?? "" {
        didSet { UserDefaults.standard.set(customPeers, forKey: "PCLSwiftUI.link.peers.v1") }
    }
    @Published var latencyFirst = UserDefaults.standard.bool(forKey: "PCLSwiftUI.link.latencyFirst.v1") {
        didSet { UserDefaults.standard.set(latencyFirst, forKey: "PCLSwiftUI.link.latencyFirst.v1") }
    }
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PCL-SwiftUI/Multiplayer") }
    private let runtime = EasyTierRuntime(directory: support.appendingPathComponent("Runtime"))
    private let session = PCLMultiplayerSession(directory: support.appendingPathComponent("Sessions"),
                                                supervisor: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PCLLinkSupervisor"))
    var isActive: Bool { phase == .preparing || phase == .connecting || phase == .connected }
    var pending: Bool { phase == .preparing || phase == .connecting }
    func create() {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port > 1024 else {
            failure = "请先在 Minecraft 中对局域网开放，并填写 1025–65535 之间的端口。"; return
        }
        do { begin(invite: try PCLInvite.create(port: port), role: .host) } catch { failure = error.localizedDescription }
    }
    func join() {
        do { let invite = try PCLInvite(inviteText); try invite.requireCustomNode(); begin(invite: invite, role: .guest) }
        catch { failure = error.localizedDescription }
    }
    private func begin(invite: PCLInvite, role: PCLLinkConfiguration.Role) {
        guard !isActive else { return }
        let peers: [String]
        do { peers = try PCLLinkPeers.parse(customPeers) } catch { failure = error.localizedDescription; return }
        let id = UUID(); operation = id; failure = nil; snapshot = nil; logs = []
        phase = .preparing; message = "检查联机环境"
        let latency = latencyFirst
        task = Task { [self] in
            do {
                if role == .host { try await LinkTCPProbe.connect(port: invite.port) }
                let binaries = try await runtime.prepare { [weak self] progress in
                    Task { @MainActor in guard let self, self.operation == id else { return }; self.message = progress }
                }
                try Task.checkCancellation()
                guard operation == id else { return }
                phase = .connecting
                try await session.open(invite: invite, role: role, peers: peers, latencyFirst: latency, binaries: binaries) { [weak self] event in
                    Task { @MainActor in guard let self, self.operation == id else { return }; self.receive(event) }
                }
            } catch is CancellationError {
                if operation == id { phase = .idle; message = "已取消联机" }
            } catch {
                if operation == id { phase = .failed; failure = invite.redacting(error.localizedDescription); message = "联机失败" }
            }
            if operation == id { task = nil }
        }
    }
    private func receive(_ event: PCLRoomEvent) {
        switch event {
        case .progress(let text): message = text
        case .output(let text):
            if !text.isEmpty { logs.append(text); if logs.count > 200 { logs.removeFirst(logs.count - 200) } }
        case .connected(let value):
            snapshot = value; phase = .connected
            message = value.reconnecting ? "连接恢复中" : (value.isHost ? "已创建房间" : "已加入房间")
        case .failed(let text): failure = text; phase = .failed; snapshot = nil; message = "联机已结束"
        }
    }
    func stop() {
        operation = UUID(); task?.cancel(); task = nil
        snapshot = nil; phase = .idle; message = "已退出联机"; failure = nil
        Task { await session.stop() }
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
                            Text(room.inviteCode).font(.system(size: 22, design: .monospaced)).textSelection(.enabled)
                            Button("复制邀请码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("在 PCL 启动器中输入邀请码【\(room.inviteCode)】，即可加入联机房间！", forType: .string) }.buttonStyle(PCLActionStyle(highlight: true))
                            Text("房主游戏端口：\(String(room.gamePort))")
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
                                Text(peer.isHost ? "房主" : peer.hostname).lineLimit(1)
                                Spacer(); Text(peer.connection)
                                Text(peer.latencyMS.map { String(format: "%.1f ms", $0) } ?? "—").frame(width: 85, alignment: .trailing)
                            }.font(.custom("PCL English", size: 12))
                        }
                    }
                }
            } else {
                PCLCard(title: "创建房间") {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(spacing: 20) {
                            PCLIcon("RoomCreate").frame(width: 40, height: 40).foregroundStyle(ClassicTheme.blue)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("邀请朋友加入你的单人游戏。").font(.custom("PCL English", size: 15))
                                Text("进入游戏，选择“对局域网开放”，然后填写游戏提示的端口。").foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Text("游戏端口").frame(width: 85, alignment: .leading)
                            TextField("例如 25565", text: $model.portText).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                            Button("创建房间") { model.create() }.buttonStyle(PCLActionStyle(highlight: true))
                        }
                    }.padding(.vertical, 15)
                }
                PCLCard(title: "加入房间") {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(spacing: 20) {
                            PCLIcon("RoomJoin").frame(width: 40, height: 40).foregroundStyle(ClassicTheme.blue)
                            Text("输入朋友发来的原版 PCL 邀请码。").font(.custom("PCL English", size: 15))
                        }
                        HStack {
                            TextField("Pxxxx-xxxxx-xxxxx-02000", text: $model.inviteText).textFieldStyle(.roundedBorder)
                            Button("加入房间") { model.join() }.buttonStyle(PCLActionStyle(highlight: true))
                        }
                    }.padding(.vertical, 15)
                }
                PCLCard(title: "连接选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Mac 与 Windows 原版 PCL 的联机设置需要填写相同的自定义节点，再创建或加入房间。")
                        Button("联机设置") { store.settingsTab = "联机"; store.page = .settings }.buttonStyle(PCLActionStyle())
                    }.font(.custom("PCL English", size: 13))
                }
            }
            if !model.logs.isEmpty {
                PCLCard(title: "联机日志", collapsible: true, expanded: false) {
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
                    Text("模式").frame(width: 110, alignment: .leading)
                    PCLComboBox(title: "模式", selection: $model.latencyFirst, options: [.init(title: "优先直连", value: false), .init(title: "优先低延迟", value: true)]).frame(height: 28)
                }
            }
            PCLCard(title: "高级设置") {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top, spacing: 20) {
                        Text("自定义节点").frame(width: 110, alignment: .leading).padding(.top, 5)
                        TextField("tcp://节点地址:端口", text: $model.customPeers, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    }
                    Text("使用逗号分隔多个节点。房主和加入者必须有至少一个相同节点。Windows 原版 PCL：设置 → 联机 → 高级设置 → 自定义节点。")
                        .foregroundStyle(.secondary)
                    Text("修改连接选项将在下一次创建或加入房间时生效。首次使用会从 EasyTier 官方 Release 下载并校验联机模块。")
                        .font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                }
            }
        }.font(.custom("PCL English", size: 13)).disabled(model.isActive)
    }
}

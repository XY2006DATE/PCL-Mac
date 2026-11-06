import AppKit
import PCLCore
import SwiftUI

struct LauncherView: View {
    @EnvironmentObject private var store: LauncherStore

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ClassicHeader()
                HStack(spacing: 0) {
                    Group {
                        if store.page == .launch { ClassicLaunchPanel() }
                        else { ClassicSectionSidebar(multiplayer: store.multiplayerState) }
                    }
                    .frame(width: sidebarWidth(for: geometry.size.width))
                    Rectangle().fill(Color.pclBlue.opacity(0.08)).frame(width: 1)
                    ZStack {
                        ClassicTheme.background
                        if let background = store.backgroundImage {
                            Image(nsImage: background).resizable()
                                .aspectRatio(contentMode: store.globalSettings.backgroundFit == "fill" ? .fill : .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                                .blur(radius: store.globalSettings.backgroundBlur)
                                .opacity(store.globalSettings.backgroundOpacity)
                        }
                        if store.page == .launch && store.globalSettings.homeMode != "blank" { CustomHomepageView() }
                        if store.page != .launch {
                            ScrollView {
                                VStack(alignment: .leading, spacing: store.page == .versionSettings ? 15 : 22) {
                                    switch store.page {
                                    case .launch: EmptyView()
                                    case .library: PCLVersionLibraryPage()
                                    case .downloads: PCLDownloadsPage()
                                    case .multiplayer: MultiplayerView(model: store.multiplayerState)
                                    case .activity: activityPage
                                    case .settings: GlobalSettingsView(launchBasics: AnyView(settingsPage))
                                    case .about: aboutPage
                                    case .versionSettings: VersionSettingsView()
                                    }
                                }
                                .padding(.horizontal, showsInstallProgress || store.page == .versionSettings ? 25 : 26)
                                .padding(.top, showsInstallProgress || store.page == .versionSettings ? 25 : 26)
                                .padding(.bottom, showsInstallProgress ? 10 : 26)
                                .frame(maxWidth: showsInstallProgress ? .infinity : 1100, alignment: .leading)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        VStack(alignment: .trailing, spacing: 0) {
                            if store.page == .downloads && store.minecraftDownloadsAvailable && store.communityState.kind == nil && store.currentRemoteSelection != nil {
                                PCLInstallButton()
                            }
                            if store.showsClassicInstallProgress && store.page != .activity {
                                PCLTaskManagerButton()
                            }
                        }.padding(15)
                    }
                }
            }
        }
        .background(ClassicTheme.panel)
        .preferredColorScheme(.light)
        .tint(.pclBlue)
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let archive = urls.first, archive.isFileURL,
                  ["zip", "mrpack"].contains(archive.pathExtension.lowercased()),
                  !store.isBusy, !store.isGameRunning else { return false }
            store.inspectModpackArchive(archive)
            return true
        }
        .sheet(isPresented: $store.showLaunchConsent) { launchConsent }
        .sheet(isPresented: $store.moddedState.showModpackSheet, onDismiss: store.dismissModpackPreview) { PCLModpackImportSheet() }
        .sheet(isPresented: $store.communityState.showDownloadSheet, onDismiss: store.dismissCommunityDownload) { PCLCommunityDownloadSheet() }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好的", role: .cancel) { store.errorMessage = nil }
            Button("查看日志") { store.errorMessage = nil; store.page = .activity }
        } message: { Text(store.text(store.errorMessage ?? "")) }
        .onChange(of: store.page) { _, page in
            store.search = ""
            if page == .downloads && store.minecraftDownloadsAvailable && store.communityState.kind == nil && store.remoteVersions.isEmpty {
                Task { await store.fetchManifest() }
            }
        }
    }

    private func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        switch store.page {
        case .launch, .library:
            return min(370, max(300, windowWidth * 0.342))
        default:
            return 200
        }
    }

    private var showsInstallProgress: Bool {
        store.page == .activity && store.showsClassicInstallProgress
    }

    @ViewBuilder private var activityPage: some View {
        if store.showsClassicInstallProgress {
            PCLDownloadProgressCard()
        } else {
            activityLogs
        }
    }

    private var activityLogs: some View {
        Group {
            PCLCard(title: "任务") {
                HStack(spacing: 10) {
                    Circle().fill(store.isGameRunning ? Color.green : Color.pclBlue).frame(width: 6, height: 6)
                    Text(store.text(store.statusMessage)).font(.custom("PCL English", size: 13))
                    Spacer()
                    if store.isGameRunning {
                        Button("结束游戏") { store.stopGame() }.buttonStyle(PCLActionStyle())
                    }
                }.padding(.vertical, 6)
            }
            PCLCard(title: "日志输出") {
                VStack(spacing: 12) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(store.logs.isEmpty ? "暂无日志" : store.logs.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced)).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }.frame(minHeight: 240, maxHeight: 400)
                    HStack(spacing: 12) {
                        Button("导出日志") { store.exportLogs() }.buttonStyle(PCLActionStyle()).disabled(store.logs.isEmpty)
                        Button("清空") { store.logs.removeAll() }.buttonStyle(PCLActionStyle()).disabled(store.logs.isEmpty)
                        Spacer()
                        Text("最多显示 2000 行").font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var settingsPage: some View {
        Group {
            PCLCard(title: "内存分配") {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 15) {
                        HStack(spacing: 7) {
                            PCLIcon("CircleFilled").frame(width: 14, height: 14).foregroundStyle(Color.pclBlue)
                            Text(store.globalSettings.memoryAuto ? "自动配置" : "自定义").font(.custom("PCL English", size: 13))
                        }.frame(width: 100, alignment: .leading)
                        Slider(value: Binding(get: { Double(store.preferences.memoryMB) }, set: { store.preferences.memoryMB = Int($0) }),
                               in: 1024...Double(store.memoryLimit), step: 512).disabled(store.globalSettings.memoryAuto)
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("游戏分配").font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                            Text(store.globalSettings.memoryAuto ? (store.selectedVersion.map { String(format: "%.1f GB", Double(store.effectiveVersionMemoryMB(for: $0)) / 1024) } ?? "按版本配置") : store.memoryLabel).font(.custom("PCL English", size: 16)).foregroundStyle(Color.pclBlue)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("物理内存").font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                            Text(String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024 / 1024)).font(.custom("PCL English", size: 16)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            PCLCard(title: "离线皮肤", collapsible: true, expanded: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("由于技术问题，此功能只保证对 1.19.2 以前的版本有效！")
                        .font(.custom("PCL English", size: 12)).foregroundStyle(Color(red: 0.57, green: 0.40, blue: 0.12))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 1, green: 0.97, blue: 0.86), in: RoundedRectangle(cornerRadius: 3))
                    HStack(spacing: 22) {
                        Picker("离线皮肤", selection: $store.offlineSkinModel) {
                            Text("随机").tag(OfflineSkinModel.automatic)
                            Text("Steve").tag(OfflineSkinModel.steve)
                            Text("Alex").tag(OfflineSkinModel.alex)
                        }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                        PCLIconLabel("正版皮肤", icon: "Circle").foregroundStyle(.tertiary).help("此选项尚未移植")
                        PCLIconLabel("自定义", icon: "Circle").foregroundStyle(.tertiary).help("此选项尚未移植")
                    }.font(.custom("PCL English", size: 13))
                }
            }
            PCLCard(title: "高级选项", collapsible: true, expanded: false) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 15) {
                        settingLabel("游戏参数")
                        TextField("额外的游戏参数", text: $store.globalSettings.gameArguments, axis: .vertical).textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 15) {
                        settingLabel("内存管理")
                        PCLComboBox(title: "内存管理", selection: $store.globalSettings.garbageCollector, options: [
                            .init(title: "尽量使用 ZGC", value: "zgc"), .init(title: "尽量使用分代 ZGC", value: "generational-zgc"),
                            .init(title: "标准 G1GC", value: "g1"), .init(title: "调优 G1GC", value: "g1tuned"),
                            .init(title: "不指定（可自定义）", value: "none")
                        ]).frame(height: 28)
                    }
                    HStack(alignment: .top, spacing: 15) {
                        settingLabel("Java 虚拟机参数").padding(.top, 6)
                        TextEditor(text: $store.preferences.extraJVMArguments)
                            .font(.custom("PCL English", size: 12)).frame(height: 90)
                            .padding(4).background(.white, in: RoundedRectangle(cornerRadius: 3))
                            .overlay { RoundedRectangle(cornerRadius: 3).stroke(Color.pclBlue.opacity(0.35), lineWidth: 1) }
                    }
                    HStack(spacing: 15) {
                        settingLabel("Java 列表")
                        PCLComboBox(title: "Java 列表", selection: $store.preferences.javaPath,
                                    options: [PCLComboBoxOption(title: "自动选择合适的 Java", value: "")] +
                                        store.javaRuntimes.map { PCLComboBoxOption(title: $0.displayName, value: $0.executable.path) })
                            .frame(maxWidth: .infinity).frame(height: 28)
                        Button { Task { await store.refreshLocal() } } label: { PCLIcon("Refresh").frame(width: 14, height: 14) }
                            .buttonStyle(PCLActionStyle()).disabled(store.scanning).help("重新搜索 Java")
                    }
                    HStack(spacing: 15) {
                        settingLabel("Java 下载源")
                        PCLComboBox(title: "Java 下载源", selection: Binding(
                            get: { store.preferences.javaDownloadSource ?? .zulu },
                            set: { store.preferences.javaDownloadSource = $0 }
                        ), options: JavaInstaller.Source.allCases.map { .init(title: $0.rawValue + " 优先", value: $0) })
                        .frame(height: 28)
                        .help("首选源下载失败时自动尝试另一个官方源")
                    }
                    HStack(spacing: 12) {
                        Spacer().frame(width: 103)
                        Button("下载 Java \(store.selectedVersion?.requiredJava ?? 21)") { store.installJava() }
                            .buttonStyle(PCLActionStyle(highlight: true)).disabled(store.isBusy || store.isGameRunning || store.scanning)
                        Button("手动导入 Java") { store.chooseJava() }.buttonStyle(PCLActionStyle())
                    }
                    if let java = store.selectedJava {
                        Text("将会使用：\(java.displayName)\n\(java.executable.path)").font(.custom("PCL English", size: 10)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    } else {
                        Text("未找到可用的 Java。可以直接下载，或手动导入已有 Java。").font(.custom("PCL English", size: 11)).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func settingLabel(_ name: String) -> some View {
        Text(name).font(.custom("PCL English", size: 13)).frame(width: 100, alignment: .leading)
    }

    private var aboutPage: some View {
        Group {
            PCLCard(title: "关于") {
                HStack(spacing: 10) {
                    PCLResourceImage(name: "Logo", fallback: "Vanilla").frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PCL Mac版").font(.custom("PCL English", size: 14))
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") · 第三方独立改编")
                            .font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                    }
                }.frame(minHeight: 45)
            }
            PCLCard(title: "鸣谢") {
                HStack(spacing: 10) {
                    PCLResourceImage(name: "LTCat", extensionName: "jpg", fallback: "Account").frame(width: 34, height: 34).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("龙腾猫跃").font(.custom("PCL English", size: 14))
                        Text("Plain Craft Launcher 原作者").font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("赞助 PCL", destination: URL(string: "https://meloong.com/afd/a/LTCat")!)
                        .buttonStyle(PCLActionStyle(highlight: true))
                }.frame(minHeight: 45)
                HStack(spacing: 10) {
                    PCLResourceImage(name: "XY2006DATE", fallback: "Account").frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("XY2006DATE").font(.custom("PCL English", size: 14))
                        Text("PCL Mac 版开发与维护").font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("查看 GitHub", destination: URL(string: "https://github.com/XY2006DATE")!)
                        .buttonStyle(PCLActionStyle())
                }.frame(minHeight: 45)
            }
            PCLCard(title: "许可与版权声明") {
                Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 14) {
                    GridRow {
                        Text("Plain Craft Launcher")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("PCL Mac 版是基于 Plain Craft Launcher 的第三方独立改编。")
                            HStack(spacing: 12) {
                                Link("查看来源网站", destination: URL(string: "https://github.com/Meloong-Git/PCL")!)
                                Button("查看许可文档") {
                                    if let license = Bundle.main.url(forResource: "LICENCE", withExtension: nil) { NSWorkspace.shared.open(license) }
                                }
                            }.buttonStyle(PCLActionStyle())
                        }
                    }
                    GridRow {
                        Text("EasyTier")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("联机运行组件，首次使用时从官方发布下载。")
                            HStack(spacing: 12) {
                                Link("查看来源网站", destination: URL(string: "https://github.com/EasyTier/EasyTier/tree/v\(EasyTierRuntime.version)")!)
                                Link("查看许可文档", destination: URL(string: "https://github.com/EasyTier/EasyTier/blob/v\(EasyTierRuntime.version)/LICENSE")!)
                            }.buttonStyle(PCLActionStyle())
                        }
                    }
                }.font(.custom("PCL English", size: 13))
                Text("Minecraft 及相关商标属于各自权利人。本应用未与 Mojang 或 Microsoft 建立关联。")
                    .font(.custom("PCL English", size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }
            PCLCard(title: "功能说明", collapsible: true, expanded: false) {
                Text("已提供原版游戏与 Forge、NeoForge、Fabric、Quilt 安装、本地整合包导入、补全文件、版本选择、Java 检测与下载、离线启动。版本设置支持组件修改、Mod 管理、完整 ZIP 与 Modrinth 整合包导出。社区资源支持 Mod、整合包、数据包、资源包与光影包的搜索、筛选、版本详情和下载安装，可自动补全必需前置 Mod。联机默认自动发现公共入口，支持 Scaffolding 大厅协议，并保留 Mac IPv6／局域网直连与原版 PCL 自定义节点模式。微软正版授权与 PCL 官方节点编号暂未接入。")
                    .font(.custom("PCL English", size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            }
        }
    }

    private var launchConsent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("考虑一下正版？").font(.custom("PCL English", size: 19)).foregroundStyle(Color.pclBlue)
            Divider()
            Text("如果觉得 Minecraft 还不错，可以购买正版支持一下，毕竟开发游戏也真的很不容易……")
                .font(.custom("PCL English", size: 13)).lineSpacing(5)
            Link("支持正版游戏！", destination: URL(string: "https://www.minecraft.net/store/minecraft-java-bedrock-edition-pc")!)
            Text("如果 PCL 还算好用的话，也欢迎赞助原作者龙腾猫跃，支持 PCL 持续开发！")
                .font(.custom("PCL English", size: 13)).lineSpacing(5)
            Link("支持 PCL！", destination: URL(string: "https://meloong.com/afd/a/LTCat")!)
            if store.launchNeedsJava, let version = store.selectedVersion {
                PCLHint(text: "此版本需要 Java \(version.requiredJava)（\(version.requiredJavaArchitecture ?? InstallPlatform.architecture)）。继续后会从官方源下载并校验 Java，安装完成后自动启动。", warning: false)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.showLaunchConsent = false }.buttonStyle(PCLActionStyle()).keyboardShortcut(.cancelAction)
                Button(store.launchNeedsJava ? "下载 Java 并启动" : "继续离线启动") { store.launchGame() }.buttonStyle(PCLActionStyle(highlight: true)).keyboardShortcut(.defaultAction)
            }.padding(.top, 4)
        }.padding(25).frame(width: 470)
    }

}

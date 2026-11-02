import AppKit
import AVFoundation
import PCLCore
import SwiftUI
import UniformTypeIdentifiers

extension GlobalLauncherSettings {
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "PCLSwiftUI.globalSettings.v1"),
              let value = try? JSONDecoder().decode(Self.self, from: data), (try? value.validate()) != nil else { return Self() }
        return value
    }
    func save() {
        guard (try? validate()) != nil else { return }
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "PCLSwiftUI.globalSettings.v1") }
    }
}

private struct SettingsBackup: Codable {
    var formatVersion = 1
    var launch: LauncherPreferences
    var settings: GlobalLauncherSettings
}

@MainActor extension LauncherStore {
    func applyPersonalization() {
        DownloadPolicy.shared.configure(maximumConcurrent: globalSettings.downloadThreads,
                                        bytesPerSecond: DownloadPolicy.speedBytes(slider: globalSettings.downloadSpeed))
        ThemePalette.apply(globalSettings)
        for window in NSApp.windows where window.title == "PCL Mac版" {
            window.alphaValue = globalSettings.opacity
        }
        if loadedBackgroundPath != globalSettings.backgroundPath {
            backgroundImage = NSImage(contentsOfFile: globalSettings.backgroundPath)
            loadedBackgroundPath = globalSettings.backgroundPath
        }
        musicPlayer?.volume = Float(globalSettings.musicVolume)
    }
    func choosePersonalFile(music: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = music ? [.audio] : [.png, .jpeg, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < (music ? 200 : 32) * 1024 * 1024 else { throw VersionManagementError.invalidSettings("文件过大，请选择较小的文件。") }
            // Keep selected media in app support, independent of the original file location.
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PCL-SwiftUI/Personalization", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            if music {
                _ = try AVAudioPlayer(contentsOf: url)
            } else if NSImage(contentsOf: url) == nil { throw VersionManagementError.invalidSettings("无法读取该图片。") }
            try FileManager.default.copyItem(at: url, to: destination)
            if music { musicPlayer?.stop(); musicPlayer = nil; globalSettings.musicPath = destination.path; playMusic() }
            else { globalSettings.backgroundPath = destination.path }
        } catch { errorMessage = error.localizedDescription }
    }
    func playMusic() {
        do {
            if musicPlayer == nil {
                musicPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: globalSettings.musicPath))
                musicPlayer?.numberOfLoops = -1
            }
            musicPlayer?.volume = Float(globalSettings.musicVolume)
            musicPlayer?.play()
        } catch { errorMessage = "背景音乐无法播放：\(error.localizedDescription)" }
    }
    func applyGameVisibility(started: Bool) {
        if started {
            if globalSettings.visibility == "hide" { NSApp.hide(nil) }
            if globalSettings.visibility == "minimize" { NSApp.windows.first(where: { $0.isVisible })?.miniaturize(nil) }
            if globalSettings.musicPauseInGame { musicPlayer?.pause() }
        } else {
            if globalSettings.visibility == "hide" { NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true) }
            if globalSettings.musicPauseInGame && globalSettings.musicAuto && !globalSettings.musicPath.isEmpty { playMusic() }
        }
    }
    func exportGlobalSettings() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "PCL-Mac-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Exclude account names, game directory, Java path and local media locations.
            var launch = preferences
            launch.playerName = ""; launch.gamePath = ""; launch.javaPath = ""; launch.selectedVersion = ""
            var settings = globalSettings; settings.backgroundPath = ""; settings.musicPath = ""
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(SettingsBackup(launch: launch, settings: settings)).write(to: url, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }
    func importGlobalSettings() {
        guard !isBusy, !isGameRunning else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 1024 * 1024 else { throw VersionManagementError.invalidSettings("设置文件过大。") }
            var backup = try JSONDecoder().decode(SettingsBackup.self, from: data)
            guard backup.formatVersion == 1, (256...memoryLimit).contains(backup.launch.memoryMB) else { throw VersionManagementError.invalidSettings("不支持的设置格式或内存值。") }
            try backup.settings.validate()
            var validation = VersionProfileSettings()
            validation.extraJVMArguments = backup.launch.extraJVMArguments
            try validation.validate()
            // Never trust imported filesystem paths or identities.
            backup.launch.playerName = preferences.playerName; backup.launch.gamePath = preferences.gamePath
            backup.launch.javaPath = preferences.javaPath; backup.launch.selectedVersion = preferences.selectedVersion
            backup.settings.backgroundPath = globalSettings.backgroundPath; backup.settings.musicPath = globalSettings.musicPath
            preferences = backup.launch; globalSettings = backup.settings
        } catch { errorMessage = error.localizedDescription }
    }
}

struct GlobalSettingsView: View {
    let launchBasics: AnyView
    @EnvironmentObject private var store: LauncherStore
    var body: some View {
        Group {
            switch store.settingsTab {
            case "个性化": personalization
            case "其他": other
            default: launch
            }
        }.font(.custom("PCL English", size: 13))
    }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 15) {
            Text(title).frame(width: 115, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 30)
    }
    private func select(_ title: String, _ selection: Binding<String>, _ options: [(String, String)]) -> some View {
        PCLComboBox(title: title, selection: selection, options: options.map { .init(title: $0.0, value: $0.1) }).frame(height: 28)
    }
    private var launch: some View {
        Group {
            PCLCard(title: "启动选项") {
                VStack(spacing: 15) {
                    row("自定义信息") { TextField("PCL", text: $store.globalSettings.customInfo).textFieldStyle(.roundedBorder) }
                    row("启动器可见性") {
                        select("启动器可见性", $store.globalSettings.visibility, [("游戏启动后隐藏，游戏退出后重新打开", "hide"), ("游戏启动后最小化", "minimize"), ("游戏启动后仍保持不变", "keep")])
                    }
                    row("窗口大小") { Toggle("全屏", isOn: $store.globalSettings.fullscreen).toggleStyle(.checkbox) }
                    row("自定义尺寸") {
                        HStack {
                            TextField("宽", value: $store.globalSettings.width, format: .number.grouping(.never)).frame(width: 75)
                            Text("×")
                            TextField("高", value: $store.globalSettings.height, format: .number.grouping(.never)).frame(width: 75)
                        }.textFieldStyle(.roundedBorder).disabled(store.globalSettings.fullscreen)
                    }
                    row("内存分配") { Toggle("自动配置", isOn: $store.globalSettings.memoryAuto).toggleStyle(.checkbox) }
                }
            }
            launchBasics

        }
    }
    private func themeChoices(_ choices: [Int]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 5), alignment: .leading, spacing: 12) {
            ForEach(choices, id: \.self) { index in
                Button { store.globalSettings.theme = index } label: {
                    HStack(spacing: 5) {
                        PCLIcon(store.globalSettings.theme == index ? "CircleFilled" : "Circle").frame(width: 13, height: 13)
                        Text(ThemePalette.names[index]).fixedSize()
                    }.foregroundStyle(store.globalSettings.theme == index ? ClassicTheme.blue : ClassicTheme.text)
                }.buttonStyle(.plain).accessibilityLabel(ThemePalette.names[index]).accessibilityValue(store.globalSettings.theme == index ? "已选择" : "未选择")
            }
        }
    }
    private var personalization: some View {
        Group {
            PCLCard(title: "基础") {
                VStack(spacing: 15) {
                    row("不透明度") { Slider(value: $store.globalSettings.opacity, in: 0.4...1) }
                    row("主题") { themeChoices([0, 1, 2, 3, 4]) }
                    row("隐藏主题") { themeChoices([5, 12, 6, 7, 13, 8, 9, 10, 11, 14]) }
                    Text("遵循原项目开源分支：主题检查直接通过。官方赞助解锁码校验未公开，本版不生成或验证官方解锁码。")
                        .font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                    if store.globalSettings.theme == 14 {
                        row("色调") { Slider(value: $store.globalSettings.themeHue, in: 0...360) }
                        row("饱和度") { Slider(value: $store.globalSettings.themeSaturation, in: 0...1) }
                        row("亮度") { Slider(value: $store.globalSettings.themeBrightness, in: 0.2...1) }
                    }
                    Link("支持 PCL 开发！", destination: URL(string: "https://meloong.com/afd/a/LTCat")!).buttonStyle(PCLActionStyle())
                }
            }
            PCLCard(title: "背景图片") {
                VStack(spacing: 15) {
                    row("自适应方式") { select("自适应方式", $store.globalSettings.backgroundFit, [("居中（保持长宽比）", "fit"), ("填满（保持长宽比）", "fill")]) }
                    row("不透明度") { Slider(value: $store.globalSettings.backgroundOpacity, in: 0...1) }
                    row("背景模糊") { Slider(value: $store.globalSettings.backgroundBlur, in: 0...50) }
                    HStack {
                        Button("更改背景图片") { store.choosePersonalFile(music: false) }
                        Button("清空背景图片") { store.globalSettings.backgroundPath = "" }.disabled(store.globalSettings.backgroundPath.isEmpty)
                    }.buttonStyle(PCLActionStyle())
                }
            }
            PCLCard(title: "背景音乐") {
                VStack(spacing: 15) {
                    row("音量") { Slider(value: $store.globalSettings.musicVolume, in: 0...1) }
                    Toggle("打开启动器自动开始播放", isOn: $store.globalSettings.musicAuto).frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("游戏启动后自动暂停播放", isOn: $store.globalSettings.musicPauseInGame).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("更改背景音乐") { store.choosePersonalFile(music: true) }
                        Button("播放") { store.playMusic() }.disabled(store.globalSettings.musicPath.isEmpty)
                        Button("暂停") { store.musicPlayer?.pause() }
                        Button("清空") { store.musicPlayer?.stop(); store.musicPlayer = nil; store.globalSettings.musicPath = "" }
                    }.buttonStyle(PCLActionStyle())
                }.toggleStyle(.checkbox)
            }
            PCLCard(title: "标题栏") { row("标题栏文本") { TextField("PCL", text: $store.globalSettings.title).textFieldStyle(.roundedBorder) } }
            PCLCard(title: "主页") {
                VStack(alignment: .leading, spacing: 15) {
                    row("主页内容") { select("主页内容", $store.globalSettings.homeMode, [("空白", "blank"), ("预设", "preset"), ("读取本地文件", "local"), ("联网更新", "network")]) }
                    if store.globalSettings.homeMode == "preset" {
                        row("主页预设") {
                            PCLComboBox(title: "主页预设", selection: $store.globalSettings.homePreset,
                                        options: HomepagePresets.all.enumerated().map { .init(title: $0.element.title, value: $0.offset) }).frame(height: 28)
                        }
                    }
                    if store.globalSettings.homeMode == "network" {
                        row("下载地址") { TextField("https://", text: $store.globalSettings.homeURL).textFieldStyle(.roundedBorder) }
                    }
                    if store.globalSettings.homeMode == "local" {
                        Text("从应用支持目录的 Homepage/Custom.xaml 读取主页。支持常用原版卡片、文字、图片和按钮；复杂 WPF 控件会提示不支持。")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("刷新主页") { store.refreshHomepage() }
                        Button("生成教学文件") { store.generateHomepageTutorial() }
                        Button("打开主页文件夹") { store.openHomepageFolder() }
                    }.buttonStyle(PCLActionStyle())
                    Text("请谨慎使用陌生人提供的主页。联网主页可能加载外部图片，按钮操作仅在点击后执行。")
                        .font(.custom("PCL English", size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var other: some View {
        Group {
            PCLCard(title: "下载") {
                VStack(spacing: 15) {
                    row("目标文件夹") {
                        HStack { Text(store.preferences.gamePath).lineLimit(2).textSelection(.enabled); Spacer(); Button("更改") { store.chooseGameDirectory() }.disabled(store.isBusy || store.isGameRunning) }
                    }
                    row("版本列表") { Toggle("显示测试版", isOn: $store.preferences.showSnapshots).toggleStyle(.checkbox) }
                    row("最大线程数") {
                        HStack {
                            Slider(value: Binding(get: { Double(store.globalSettings.downloadThreads) }, set: { store.globalSettings.downloadThreads = Int($0) }), in: 1...256, step: 1)
                            Text("\(store.globalSettings.downloadThreads)").monospacedDigit().frame(width: 40)
                        }
                    }
                    row("速度限制") {
                        HStack {
                            Slider(value: Binding(get: { Double(store.globalSettings.downloadSpeed) }, set: { store.globalSettings.downloadSpeed = Int($0) }), in: 0...42, step: 1)
                            let bytes = DownloadPolicy.speedBytes(slider: store.globalSettings.downloadSpeed)
                            Text(bytes == 0 ? "无限制" : String(format: "%.1f M/s", Double(bytes) / 1_048_576)).monospacedDigit().frame(width: 85)
                        }
                    }
                    Text("线程数为所有文件下载共享的并发上限；速度限制为合计下载速度，缓存复制不计入网络流量。官方源及镜像候选仍按下载器规则选择。")
                        .foregroundStyle(.secondary)
                }
            }
            PCLCard(title: "启动器") {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Link("检查更新", destination: URL(string: "https://github.com/XY2006DATE/PCL-Mac/releases/latest")!)
                        Button("导出设置") { store.exportGlobalSettings() }
                        Button("导入设置") { store.importGlobalSettings() }.disabled(store.isBusy || store.isGameRunning)
                    }.buttonStyle(PCLActionStyle())
                    Text("导出仅包含启动和界面设置，不包含账户记录、游戏文件夹、Java 或媒体文件路径。导入保留本机账户和文件位置。")
                        .foregroundStyle(.secondary)
                    Button("打开下载缓存") {
                        let folder = store.gameDirectory.appendingPathComponent("PCL/download-cache")
                        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
                        catch { store.errorMessage = error.localizedDescription }
                    }.buttonStyle(PCLActionStyle())
                }
            }
            PCLCard(title: "调试选项") {
                HStack {
                    Button("启动日志") { store.page = .activity }
                    Button("导出日志") { store.exportLogs() }.disabled(store.logs.isEmpty)
                }.buttonStyle(PCLActionStyle())
            }
        }
    }
}

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
    private var personalization: some View {
        Group {
            PCLCard(title: "基础") {
                VStack(spacing: 15) {
                    row("不透明度") { Slider(value: $store.globalSettings.opacity, in: 0.4...1) }
                    row("主题") { Text("龙猫蓝").foregroundStyle(ClassicTheme.blue) }
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
            PCLCard(title: "主页") { Text("当前使用空白主页。原版 XAML 自定义主页、联网主页与功能隐藏尚未移植。 ").foregroundStyle(.secondary) }
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
                    Text("下载器自动尝试官方源及已实现的镜像候选，并验证文件哈希。手动源优先级、线程数和速度限制尚未移植。")
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

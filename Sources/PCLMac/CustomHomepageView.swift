import AppKit
import CryptoKit
import SwiftUI
import PCLCore

@MainActor extension LauncherStore {
    var homepageFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PCL-SwiftUI/Homepage")
    }
    func openHomepageFolder() {
        do { try FileManager.default.createDirectory(at: homepageFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(homepageFolder) }
        catch { errorMessage = error.localizedDescription }
    }
    func generateHomepageTutorial() {
        do {
            try FileManager.default.createDirectory(at: homepageFolder, withIntermediateDirectories: true)
            let file = homepageFolder.appendingPathComponent("Custom.xaml")
            if !FileManager.default.fileExists(atPath: file.path) {
                let sample = """
                <!-- PCL Mac版主页。支持 MyCard、TextBlock、MyHint、MyButton、MyImage、StackPanel 和 Grid。 -->
                <local:MyCard Title="欢迎回来" CanSwap="True" IsSwapped="False">
                  <StackPanel>
                    <TextBlock Text="欢迎使用 PCL Mac版！" FontSize="18" />
                    <local:MyHint Text="在此文件中编辑主页，保存后点击刷新主页。" Theme="Blue" />
                    <local:MyButton Text="Minecraft Wiki" EventType="打开网页" EventData="https://zh.minecraft.wiki/" />
                  </StackPanel>
                </local:MyCard>
                """
                try Data(sample.utf8).write(to: file, options: .withoutOverwriting)
            }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch { errorMessage = error.localizedDescription }
    }
    func refreshHomepage() {
        homepageTask?.cancel()
        let configuration = globalSettings
        homepageTask = Task {
            homepageLoading = true; homepageError = nil; homepageNodes = []
            defer { if !Task.isCancelled { homepageLoading = false } }
            do {
                if configuration.homeMode == "network" { try await Task.sleep(nanoseconds: 500_000_000) }
                let data: Data
                switch configuration.homeMode {
                case "blank": homepageNodes = []; homepageLoading = false; return
                case "local": data = try Data(contentsOf: homepageFolder.appendingPathComponent("Custom.xaml"))
                case "preset" where configuration.homePreset < 2:
                    let title = HomepagePresets.all[configuration.homePreset].title
                    let messages = ["为便于维护，原项目开源内容中不包含百宝箱功能及此预设的数据源。"]
                    data = Data("<local:MyCard Title=\"\(title)\"><TextBlock Text=\"\(messages.randomElement()!)\"/><local:MyButton Text=\"换一条\" EventType=\"刷新主页\"/></local:MyCard>".utf8)
                default:
                    let address = configuration.homeMode == "preset" ? HomepagePresets.all[configuration.homePreset].url : configuration.homeURL
                    guard let url = URL(string: address), url.scheme == "https", url.host != nil else { throw NSError(domain: "PCL.Homepage", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写有效的 HTTPS 主页地址。"] ) }
                    data = try await homepageContent(url: url)
                }
                let nodes = try await Task.detached { try CustomHomepage.parse(data) }.value
                try Task.checkCancellation()
                homepageNodes = nodes
            } catch is CancellationError {} catch {
                if !Task.isCancelled { homepageError = error.localizedDescription }
            }
        }
    }
    private func homepageContent(url: URL) async throws -> Data {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = homepageFolder.appendingPathComponent("Cache/" + digest + ".xaml")
        var request = URLRequest(url: url); request.timeoutInterval = 30
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration, delegate: HomepageRedirectPolicy(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (content, response) = try await PCLHTTPS.data(for: request, session: session)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw URLError(.badServerResponse) }
            _ = try CustomHomepage.parse(content)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: cache, options: .atomic)
            return content
        } catch {
            try Task.checkCancellation()
            if let cached = try? Data(contentsOf: cache) {
                appendLog("主页联网更新失败，使用此地址的已保存缓存。")
                return cached
            }
            throw error
        }
    }
    func homepageEvent(_ node: HomepageNode) {
        let kind = node.attributes["EventType"] ?? ""
        let data = node.attributes["EventData"] ?? ""
        switch kind {
        case "", "无": break
        case "刷新主页": refreshHomepage()
        case "打开网页":
            if let url = URL(string: data), ["https", "http"].contains(url.scheme), url.host != nil { NSWorkspace.shared.open(url) }
            else { errorMessage = "主页按钮的网址无效。" }
        case "弹出窗口":
            let parts = data.components(separatedBy: "|")
            let alert = NSAlert(); alert.messageText = parts.first ?? "主页"
            alert.informativeText = parts.dropFirst().joined(separator: "|"); alert.runModal()
        case "启动游戏": requestLaunch()
        case "打开帮助": NSWorkspace.shared.open(URL(string: "https://github.com/Meloong-Git/PCL/wiki")!)
        default: errorMessage = "此主页事件尚不支持：\(kind)"
        }
    }
}

struct CustomHomepageView: View {
    @EnvironmentObject private var store: LauncherStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                if store.homepageLoading { ProgressView("正在加载主页") }
                if let error = store.homepageError {
                    PCLCard(title: "主页加载失败") {
                        Text(error).foregroundStyle(.secondary)
                        Button("重新加载") { store.refreshHomepage() }.buttonStyle(PCLActionStyle())
                    }
                }
                ForEach(store.homepageNodes) { node in HomepageElement(node: node) }
            }.padding(25).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HomepageElement: View {
    @EnvironmentObject private var store: LauncherStore
    let node: HomepageNode
    private var content: String { node.attributes["Text"] ?? node.attributes["Content"] ?? node.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        rendered
            .frame(maxWidth: .infinity, alignment: alignment)
            .help(node.attributes["ToolTip"] ?? "")
            .opacity(node.attributes["Visibility"] == "Collapsed" ? 0 : 1)
    }
    private var alignment: Alignment {
        switch node.attributes["HorizontalAlignment"] { case "Center": return .center; case "Right": return .trailing; default: return .leading }
    }
    private var children: some View {
        ForEach(node.children) { child in HomepageElement(node: child) }
    }
    private var rendered: AnyView {
        switch node.kind {
        case "MyCard":
            return AnyView(PCLCard(title: node.attributes["Title"] ?? "", collapsible: node.attributes["CanSwap"] == "True", expanded: node.attributes["IsSwapped"] != "True") { VStack(alignment: .leading, spacing: 10) { children } })
        case "TextBlock", "Run":
            return AnyView(Text(content).font(.custom("PCL English", size: min(60, max(9, Double(node.attributes["FontSize"] ?? "13") ?? 13)))).textSelection(.enabled).fixedSize(horizontal: false, vertical: true))
        case "MyHint": return AnyView(PCLHint(text: content, warning: node.attributes["Theme"] != "Blue"))
        case "MyButton", "MyTextButton", "MyIconTextButton", "MyIconButton", "MyListItem", "Button":
            return AnyView(Button(content.isEmpty ? (node.attributes["Title"] ?? node.attributes["EventType"] ?? "按钮") : content) { store.homepageEvent(node) }.buttonStyle(PCLActionStyle(highlight: node.attributes["ColorType"] == "Highlight")))
        case "MyImage", "Image":
            if let address = node.attributes["Source"], let url = URL(string: address), url.scheme == "https" {
                return AnyView(AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }.frame(maxHeight: min(800, Double(node.attributes["Height"] ?? "180") ?? 180)))
            }
            return AnyView(Text("图片地址需为 HTTPS").foregroundStyle(.secondary))
        case "Grid":
            let items = node.children.filter { !$0.kind.contains("Definition") }
            let rows = Array(Set(items.map { Int($0.attributes["Grid.Row"] ?? "0") ?? 0 })).sorted()
            return AnyView(Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(items.filter { (Int($0.attributes["Grid.Row"] ?? "0") ?? 0) == row }.sorted { (Int($0.attributes["Grid.Column"] ?? "0") ?? 0) < (Int($1.attributes["Grid.Column"] ?? "0") ?? 0) }) { child in
                            HomepageElement(node: child).gridCellColumns(min(12, max(1, Int(child.attributes["Grid.ColumnSpan"] ?? "1") ?? 1)))
                        }
                    }
                }
            })
        case "StackPanel", "WrapPanel", "Border", "ScrollViewer", "Page", "UserControl":
            if node.attributes["Orientation"] == "Horizontal" { return AnyView(HStack(alignment: .top, spacing: 10) { children }) }
            return AnyView(VStack(alignment: .leading, spacing: 10) { children })
        case "Grid.RowDefinitions", "Grid.ColumnDefinitions", "RowDefinition", "ColumnDefinition": return AnyView(EmptyView())
        case "Separator": return AnyView(Divider())
        default: return AnyView(Text("不支持的主页控件：\(node.kind)").foregroundStyle(.orange))
        }
    }
}

private final class HomepageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

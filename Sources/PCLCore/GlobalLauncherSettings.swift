import Foundation

public struct GlobalLauncherSettings: Codable, Equatable, Sendable {
    public var memoryAuto = false
    public var width = 1100
    public var height = 700
    public var fullscreen = false
    public var customInfo = ""
    public var gameArguments = ""
    public var garbageCollector = "none"
    public var visibility = "keep"
    public var title = ""
    public var opacity = 1.0
    public var backgroundPath = ""
    public var backgroundFit = "fill"
    public var backgroundOpacity = 0.7
    public var backgroundBlur = 0.0
    public var musicPath = ""
    public var musicVolume = 0.5
    public var musicAuto = false
    public var musicPauseInGame = false
    public var downloadThreads = 64
    public var downloadSpeed = 42
    public var homeMode = "blank"
    public var homeURL = ""
    public var homePreset = 0
    public var theme = 0
    public var themeHue = 210.0
    public var themeSaturation = 0.85
    public var themeBrightness = 0.8
    public init() {}

    private enum CodingKeys: String, CodingKey { case memoryAuto, width, height, fullscreen, customInfo, gameArguments, garbageCollector, visibility, title, opacity, backgroundPath, backgroundFit, backgroundOpacity, backgroundBlur, musicPath, musicVolume, musicAuto, musicPauseInGame, downloadThreads, downloadSpeed, homeMode, homeURL, homePreset, theme, themeHue, themeSaturation, themeBrightness }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memoryAuto = try c.decodeIfPresent(Bool.self, forKey: .memoryAuto) ?? false
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1100
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 700
        fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? false
        customInfo = try c.decodeIfPresent(String.self, forKey: .customInfo) ?? ""
        gameArguments = try c.decodeIfPresent(String.self, forKey: .gameArguments) ?? ""
        garbageCollector = try c.decodeIfPresent(String.self, forKey: .garbageCollector) ?? "none"
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "keep"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        backgroundPath = try c.decodeIfPresent(String.self, forKey: .backgroundPath) ?? ""
        backgroundFit = try c.decodeIfPresent(String.self, forKey: .backgroundFit) ?? "fill"
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.7
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0.0
        musicPath = try c.decodeIfPresent(String.self, forKey: .musicPath) ?? ""
        musicVolume = try c.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.5
        musicAuto = try c.decodeIfPresent(Bool.self, forKey: .musicAuto) ?? false
        musicPauseInGame = try c.decodeIfPresent(Bool.self, forKey: .musicPauseInGame) ?? false
        downloadThreads = try c.decodeIfPresent(Int.self, forKey: .downloadThreads) ?? 64
        downloadSpeed = try c.decodeIfPresent(Int.self, forKey: .downloadSpeed) ?? 42
        homeMode = try c.decodeIfPresent(String.self, forKey: .homeMode) ?? "blank"
        homeURL = try c.decodeIfPresent(String.self, forKey: .homeURL) ?? ""
        homePreset = try c.decodeIfPresent(Int.self, forKey: .homePreset) ?? 0
        theme = try c.decodeIfPresent(Int.self, forKey: .theme) ?? 0
        themeHue = try c.decodeIfPresent(Double.self, forKey: .themeHue) ?? 210.0
        themeSaturation = try c.decodeIfPresent(Double.self, forKey: .themeSaturation) ?? 0.85
        themeBrightness = try c.decodeIfPresent(Double.self, forKey: .themeBrightness) ?? 0.8
    }


    public func validate() throws {
        guard (1...256).contains(downloadThreads), (0...42).contains(downloadSpeed),
              ["blank", "preset", "local", "network"].contains(homeMode), (0...24).contains(homePreset),
              (0...14).contains(theme), (0...360).contains(themeHue), (0...1).contains(themeSaturation),
              (0.2...1).contains(themeBrightness),
              (320...16384).contains(width), (240...16384).contains(height),
              (0.4...1).contains(opacity), (0...1).contains(backgroundOpacity),
              (0...50).contains(backgroundBlur), (0...1).contains(musicVolume),
              ["keep", "hide", "minimize"].contains(visibility),
              ["fill", "fit"].contains(backgroundFit),
              ["none", "g1", "g1tuned", "zgc", "generational-zgc"].contains(garbageCollector),
              ![customInfo, gameArguments, title, backgroundPath, musicPath].contains(where: { $0.contains("\0") }) else {
            throw VersionManagementError.invalidSettings("设置包含超出范围的值")
        }
        _ = try MinecraftArguments.tokenize(gameArguments)
    }
}

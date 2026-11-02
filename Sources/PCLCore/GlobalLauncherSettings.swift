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
    public init() {}

    public func validate() throws {
        guard (320...16384).contains(width), (240...16384).contains(height),
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

import Foundation

enum InterfaceLanguage: String, CaseIterable, Codable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    var locale: Locale {
        if self == .system {
            let preferred = Locale(identifier: Locale.preferredLanguages.first ?? "en")
            return preferred.language.languageCode?.identifier == "zh" ? Locale(identifier: "zh-Hans") : Locale(identifier: "en")
        }
        return Locale(identifier: rawValue)
    }

    private static let englishBundle = PCLResources.url("Localizable", extension: "strings", subdirectory: "en.lproj")
        .flatMap { Bundle(url: $0.deletingLastPathComponent()) }

    /// Labels already held in String values do not use SwiftUI's localized literal lookup.
    static func text(_ key: String, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "en" else { return key }
        return englishBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

@MainActor extension LauncherStore {
    var interfaceLocale: Locale { (preferences.interfaceLanguage ?? .system).locale }

    func text(_ key: String) -> String { InterfaceLanguage.text(key, locale: interfaceLocale) }

    var effectiveDownloadRegion: String? {
        if let region = preferences.downloadRegion?.uppercased(), Locale.Region.isoRegions.contains(Locale.Region(region)) {
            return region
        }
        return Locale.autoupdatingCurrent.region?.identifier
    }

    var minecraftDownloadsAvailable: Bool { effectiveDownloadRegion != "CN" }

    var minecraftDownloadRegionMessage: String {
        text("当前下载地区为中国大陆。启动器暂不支持在此地区下载 Minecraft，可在设置中切换下载地区。")
    }

    func checkMinecraftDownloadRegion() -> Bool {
        guard minecraftDownloadsAvailable else {
            errorMessage = minecraftDownloadRegionMessage
            return false
        }
        return true
    }

    func openDownloadRegionSettings() {
        settingsTab = "其他"
        page = .settings
    }
}

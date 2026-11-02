import AppKit
import PCLCore
import SwiftUI

enum ThemePalette {
    static let names = ["龙猫蓝", "甜柠青", "小草绿", "菠萝黄", "橡木棕", "玄素黑", "铁杆粉", "神秘紫", "秋仪金", "活跃橙", "跳票红", "极客蓝", "滑稽彩", "欧皇彩", "自定义"]
    static var hue = 210.0
    static var saturation = 0.85
    static var brightness = 0.81
    static var selection = 0
    static func apply(_ settings: GlobalLauncherSettings) {
        selection = settings.theme
        let hues: [Double] = [210, 172, 110, 48, 30, 210, 330, 275, 43, 24, 0, 225, 55, 300, settings.themeHue]
        hue = hues[min(14, max(0, selection))]
        saturation = selection == 5 ? 0 : (selection == 14 ? settings.themeSaturation : 0.85)
        brightness = selection == 5 ? 0.3 : (selection == 14 ? settings.themeBrightness : 0.81)
    }
    static var adjustment: Double { selection == 5 ? -20 : (selection == 14 ? (brightness - 0.8) * 50 : 0) }
    static var blue: Color { color(hue, saturation, 55 + adjustment) }
    static func color(_ hue: Double, _ saturation: Double, _ lightness: Double) -> Color {
        let rgb = OriginalThemeColor.rgb(hue: hue, saturation: saturation * 100, lightness: lightness)
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
    static var header: LinearGradient {
        let delta = selection == 12 || selection == 13 ? 60.0 : 0.0
        return LinearGradient(colors: [color(hue - delta, saturation, 48 + adjustment),
                                        color(hue, saturation, 54 + adjustment),
                                        color(hue + delta, saturation, 48 + adjustment)], startPoint: .leading, endPoint: .trailing)
    }
    static var background: LinearGradient {
        LinearGradient(colors: [color(hue - 15, saturation * 0.8, 91), color(hue, saturation * 0.8, 91),
                                color(hue + 15, saturation * 0.8, 91)], startPoint: .topTrailing, endPoint: .bottomLeading)
    }
}

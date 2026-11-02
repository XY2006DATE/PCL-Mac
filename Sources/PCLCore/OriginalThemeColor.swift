import Foundation

/// ModBase.MyColor.FromHSL2: hue-dependent perceptual lightness adjustment.
public enum OriginalThemeColor {
    public static func rgb(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let s = max(0, min(100, saturation))
        var l = max(0, min(100, lightness))
        if s == 0 { return (l / 100, l / 100, l / 100) }
        let cent = [0.1, -0.06, -0.3, -0.19, -0.15, -0.24, -0.32, -0.09, 0.18, 0.05, -0.12, -0.02, 0.1, -0.06]
        let position = h / 30, index = Int(floor(h / 30))
        let center = 50 - ((1 - position + Double(index)) * cent[index] + (position - Double(index)) * cent[index + 1]) * s
        l = (l < center ? l / center : 1 + (l - center) / (100 - center)) * 0.5
        let upper = l < 0.5 ? s / 100 * l + l : s / 100 * (1 - l) + l
        let lower = 2 * l - upper
        func channel(_ input: Double) -> Double {
            var value = input
            if value < 0 { value += 1 }; if value > 1 { value -= 1 }
            if value < 0.16667 { return lower + (upper - lower) * 6 * value }
            if value < 0.5 { return upper }
            if value < 0.66667 { return lower + (upper - lower) * (4 - value * 6) }
            return lower
        }
        return (channel(h / 360 + 1 / 3), channel(h / 360), channel(h / 360 - 1 / 3))
    }
}

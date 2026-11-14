import Foundation

/// An sRGB color with components from 0 to 1, for checking contrast.
public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A color written as 0xRRGGBB.
    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    public static let white = RGB(hex: 0xFFFFFF)
    public static let black = RGB(hex: 0x000000)

    /// This color painted at `alpha` over `base`.
    public func over(_ base: RGB, alpha: Double) -> RGB {
        RGB(
            red: red * alpha + base.red * (1 - alpha),
            green: green * alpha + base.green * (1 - alpha),
            blue: blue * alpha + base.blue * (1 - alpha)
        )
    }

    /// Relative luminance as the Web Content Accessibility Guidelines (WCAG) define it:
    /// 0 for black, 1 for white.
    public var luminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio, from 1 (none) to 21 (black on white). Body text needs
    /// at least 4.5.
    public static func contrast(_ first: RGB, _ second: RGB) -> Double {
        let lighter = max(first.luminance, second.luminance)
        let darker = min(first.luminance, second.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// The colors stew draws status text in: outcomes, severities, notices. Each has a
/// darker shade for light mode and a lighter one for dark mode, chosen so the text
/// keeps a contrast of at least 4.5 on its own tinted capsule, also in a selected row.
public enum Tone: CaseIterable, Sendable {
    case green, red, blue, orange, amber, teal, paprika

    public var light: RGB {
        switch self {
        case .green: RGB(hex: 0x185C29)
        case .red: RGB(hex: 0x96231C)
        case .blue: RGB(hex: 0x064F99)
        case .orange: RGB(hex: 0x863808)
        case .amber: RGB(hex: 0x664B00)
        case .teal: RGB(hex: 0x00585E)
        case .paprika: RGB(hex: 0x89341C)
        }
    }

    public var dark: RGB {
        switch self {
        case .green: RGB(hex: 0x65E178)
        case .red: RGB(hex: 0xFFB8B4)
        case .blue: RGB(hex: 0x9FCFFF)
        case .orange: RGB(hex: 0xFFBE58)
        case .amber: RGB(hex: 0xF2C353)
        case .teal: RGB(hex: 0x36DBE7)
        case .paprika: RGB(hex: 0xF9BCAA)
        }
    }

    /// How strongly a capsule or banner is tinted with its tone.
    public static let fillAlpha = 0.15
}

/// Secondary text: black or white at this opacity. Stronger than the system's
/// secondary label (0.5 and 0.55), which is below 4.5 on a light grey window.
public enum Ink {
    public static let secondaryLightAlpha = 0.66
    public static let secondaryDarkAlpha = 0.72
}

/// The opaque surfaces stew draws on: the window background in each appearance, and
/// the tints a selected or hovered list row adds on top.
public enum Surface {
    /// The lightest and darkest window background in light mode, and in dark mode.
    /// macOS draws some windows in the older grey shades.
    public static let light = [RGB.white, RGB(hex: 0xECECEC)]
    public static let dark = [RGB(hex: 0x1E1E1E), RGB(hex: 0x323232)]
    public static let paprikaLight = RGB(hex: 0xE4572E)
    public static let paprikaDark = RGB(hex: 0xF26A42)
    /// A selected row in the focused list.
    public static let selectedAlpha = 0.16
    /// A selected row in a list without the keyboard, or a hovered one.
    public static let neutralSelectedAlpha = 0.07

    /// Every surface status text sits on: each window shade, alone and under a
    /// selected row in either form.
    public static func all(dark isDark: Bool) -> [RGB] {
        let paprika = isDark ? paprikaDark : paprikaLight
        let ink = isDark ? RGB.white : RGB.black
        return (isDark ? dark : light).flatMap { window in
            [window, paprika.over(window, alpha: selectedAlpha), ink.over(window, alpha: neutralSelectedAlpha)]
        }
    }
}

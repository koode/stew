import AppKit
import SwiftUI
import StewCore

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

extension Tone {
    /// The tone's text color, darker in light mode and lighter in dark mode. Checked
    /// for contrast in ContrastTests.
    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.nsColor : light.nsColor
        })
    }
}

extension Ink {
    /// Secondary text, stronger than the system's secondary label.
    static let secondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: secondaryDarkAlpha)
            : NSColor(white: 0, alpha: secondaryLightAlpha)
    })
}

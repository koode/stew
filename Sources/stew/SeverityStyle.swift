import AppKit
import SwiftUI
import StewCore

extension Severity {
    /// Low is neutral, medium amber, high orange, critical red.
    var tone: Color {
        switch self {
        case .low: .secondary
        case .medium: Self.amber
        case .high: .orange
        case .critical: .red
        }
    }

    /// Darker in light mode and lighter in dark mode, so the chip's text keeps its
    /// contrast on the tinted capsule.
    private static let amber = Color(nsColor: NSColor(name: "stew.amber") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xF2 / 255, green: 0xC1 / 255, blue: 0x4E / 255, alpha: 1)
            : NSColor(srgbRed: 0xA6 / 255, green: 0x6A / 255, blue: 0x00 / 255, alpha: 1)
    })
}

/// The one form of a severity: the status capsule with the level's name and tone, in
/// the panel and in the history alike.
struct SeverityPill: View {
    let severity: Severity

    var body: some View {
        StatusPill(text: severity.label, tone: severity.tone)
    }
}

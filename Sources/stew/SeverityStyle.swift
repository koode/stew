import AppKit
import SwiftUI
import StewCore

extension Severity {
    /// Low is neutral, medium amber, high orange, critical red.
    var tone: Color {
        switch self {
        case .low: Ink.secondary
        case .medium: Tone.amber.color
        case .high: Tone.orange.color
        case .critical: Tone.red.color
        }
    }
}

/// The one form of a severity: the status capsule with the level's name and tone, in
/// the panel and in the history alike.
struct SeverityPill: View {
    let severity: Severity

    var body: some View {
        StatusPill(text: severity.label, tone: severity.tone)
    }
}

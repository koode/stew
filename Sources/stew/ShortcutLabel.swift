import SwiftUI
import StewCore

extension Shortcut {
    /// The shortcut as one Text, drawn like a macOS menu: modifiers and special keys as
    /// SF Symbols, letters as text, all in the surrounding font and on one baseline.
    /// Being a Text, it also fits inside a sentence ("Choose any, then ⌘↩ to confirm.").
    var text: Text {
        glyphs.reduce(Text(verbatim: "")) { partial, glyph in
            switch glyph {
            case .symbol(let name): Text("\(partial)\(Image(systemName: name))")
            case .text(let value): Text("\(partial)\(value)")
            }
        }
    }
}

extension Array where Element == Shortcut {
    /// Several shortcuts in one Text, separated by spaces.
    var text: Text {
        enumerated().reduce(Text(verbatim: "")) { partial, entry in
            entry.offset == 0 ? entry.element.text : Text("\(partial) \(entry.element.text)")
        }
    }
}

/// A shortcut on its own, for places that hold a view rather than a sentence.
struct ShortcutLabel: View {
    let shortcut: Shortcut

    var body: some View {
        shortcut.text
    }
}

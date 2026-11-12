import AppKit
import StewCore

/// The menu bar item for open needs items. It exists only while at least one is open,
/// shows how many, and its menu opens each one in the panel.
final class NeedsStatusItem: NSObject {
    private var statusItem: NSStatusItem?
    private let onOpen: (String) -> Void
    private let onOpenHistory: () -> Void

    init(onOpen: @escaping (String) -> Void, onOpenHistory: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onOpenHistory = onOpenHistory
    }

    func update(_ open: [NeedsItem]) {
        guard !open.isEmpty else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            let image = NSImage(systemSymbolName: NeedsStyle.symbol, accessibilityDescription: "Needs you")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            // Tabular digits, so the item keeps its width as the count changes.
            button.attributedTitle = NSAttributedString(string: " \(open.count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            ])
            button.toolTip = NeedsBook.countText(open.count)
        }
        item.menu = menu(for: open)
    }

    private func menu(for open: [NeedsItem]) -> NSMenu {
        let menu = NSMenu()
        let heading = NSMenuItem(title: NeedsBook.countText(open.count), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for record in open {
            let entry = NSMenuItem(title: record.menuTitle, action: #selector(openItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = record.id
            entry.toolTip = record.session.cwd
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let history = NSMenuItem(title: "Open history", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        return menu
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onOpen(id)
    }

    @objc private func openHistory() {
        onOpenHistory()
    }
}

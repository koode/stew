import AppKit
import SwiftUI
import StewCore

/// The pause as the settings window shows it.
final class PauseModel: ObservableObject {
    @Published var display: PauseDisplay?
    var onPause: (PauseChoice) -> Void = { _ in }
    var onResume: () -> Void = {}

    init(display: PauseDisplay? = nil) {
        self.display = display
    }
}

/// The stew item in the menu bar: the app icon with what waits on the user. A click
/// opens the popover with the open needs items and the recent requests; a right-click or
/// control-click opens the menu for the open needs items, History, Settings, the pause
/// and a waiting update.
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var state = MenuBarState()
    /// The right-click menu. It is the status item's menu only while it is open, so a
    /// left click reaches the popover.
    private let menu = NSMenu()
    /// Counts down "Pausing in 0:45…" while the menu is open.
    private var countdown: Timer?
    let popover = MenuBarPopoverController()
    /// The history for the popover, read when it opens.
    var historyEntries: () -> [HistoryEntry] = { [] }
    var onOpenNeeds: (String) -> Void = { _ in }
    var onHistory: () -> Void = {}
    var onSettings: () -> Void = {}
    var onPause: (PauseChoice) -> Void = { _ in }
    var onResume: () -> Void = {}
    var onUpdate: () -> Void = {}
    var onHide: () -> Void = {}

    func update(_ state: MenuBarState) {
        self.state = state
        popover.model.state = state
        guard state.isVisible else {
            popover.close()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = StatusIcon.image(for: state.icon)
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = StatusIcon.description(of: state)
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.autoenablesItems = false
        menu.delegate = self
        fill(menu, with: state.entries(timeText: Coordinator.clockText))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.close()
            showMenu()
        } else {
            popover.toggle(from: sender, entries: historyEntries())
        }
    }

    /// The menu opens the way a status item's own menu does, under the item.
    private func showMenu() {
        guard let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func fill(_ menu: NSMenu, with entries: [MenuEntry]) {
        menu.removeAllItems()
        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(entry.action)
            item.isEnabled = entry.isEnabled
            item.toolTip = entry.toolTip
            if let badge = entry.badge { item.badge = NSMenuItemBadge(count: badge) }
            if entry.hasSubmenu {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                fill(submenu, with: entry.submenu)
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }

    /// Titles that depend on the time, such as "Until 08:00" and the countdown, are
    /// current each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        fill(menu, with: state.entries(timeText: Coordinator.clockText))
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu, case .startsAt = state.pause else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak menu] _ in
            guard let self, let menu else { return }
            self.refreshTitles(of: menu)
        }
        // Common modes, so it also fires while the menu tracks the mouse.
        RunLoop.main.add(timer, forMode: .common)
        countdown = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        countdown?.invalidate()
        countdown = nil
    }

    /// Updates the titles of the open menu in place, so it stays open.
    private func refreshTitles(of menu: NSMenu) {
        let entries = state.entries(timeText: Coordinator.clockText)
        guard entries.count == menu.items.count else { return }
        for (entry, item) in zip(entries, menu.items) where !entry.isSeparator && item.title != entry.title {
            item.title = entry.title
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? MenuAction)?.action else { return }
        switch action {
        case .none: break
        case .openNeeds(let id): onOpenNeeds(id)
        case .history: onHistory()
        case .settings: onSettings()
        case .pause(let choice): onPause(choice)
        case .resume: onResume()
        case .update: onUpdate()
        case .hide: onHide()
        }
    }

    /// A menu item's action, boxed for `representedObject`.
    private final class MenuAction: NSObject {
        let action: MenuEntry.Action
        init(_ action: MenuEntry.Action) { self.action = action }
    }
}

/// The menu bar icon: the app icon (the cream pot on a paprika tile) redrawn for 16 pt,
/// on whole pixels at 1x and 2x. The site's dark edge and hard shadow are left out, and
/// the steam and handles are thicker, so it stays a pot at this size. In color it is not
/// a template, so it looks the same on light and dark menu bars and when highlighted:
/// grey while paused, a blue dot at the corner for an update, and a paprika pill beside
/// it with what waits on the user. Monochrome is the pot alone as a template that macOS
/// tints: faded while paused, a plain dot, and a pill with the digits cut out.
enum StatusIcon {
    static let tile: CGFloat = 16
    static let height: CGFloat = 18
    private static let pillHeight: CGFloat = 11
    private static let pillGap: CGFloat = 3
    private static let dotRadius: CGFloat = 2.5
    private static let dotRing: CGFloat = 1

    static let paprika = NSColor(srgbRed: 0xE4 / 255, green: 0x57 / 255, blue: 0x2E / 255, alpha: 1)
    static let cream = NSColor(srgbRed: 0xFF / 255, green: 0xF6 / 255, blue: 0xEC / 255, alpha: 1)
    private static let pausedTile = NSColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 1)
    private static let pausedPot = NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255, alpha: 1)
    private static let updateBlue = NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1)
    /// The monochrome pot while paused: faded, as macOS shows an inactive item.
    private static let pausedInkAlpha: CGFloat = 0.4

    private static var pillFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
    }

    /// The image with a 1x and a 2x drawing, so each screen gets whole pixels.
    static func image(for icon: MenuBarIcon) -> NSImage {
        let image = NSImage(size: size(for: icon))
        for scale in [1, 2] {
            image.addRepresentation(bitmap(for: icon, scale: scale))
        }
        image.isTemplate = icon.monochrome
        image.accessibilityDescription = "stew"
        return image
    }

    /// The tooltip and the words for VoiceOver.
    static func description(of state: MenuBarState) -> String {
        var parts = ["stew"]
        switch state.pause {
        case .until(let date): parts.append("paused until \(Coordinator.clockText(date))")
        case .untilBack: parts.append("paused until you're back")
        // The tooltip is not redrawn each second, so it gives no countdown.
        case .startsAt: parts.append("pausing soon")
        case nil: break
        }
        if !state.openNeeds.isEmpty { parts.append(NeedsBook.countText(state.openNeeds.count)) }
        if state.missedCount > 0 { parts.append(state.missedCount == 1 ? "1 missed request" : "\(state.missedCount) missed requests") }
        if state.update != nil { parts.append("an update is waiting") }
        return parts.joined(separator: ", ")
    }

    static func size(for icon: MenuBarIcon) -> NSSize {
        var width = tile
        if icon.updateDot { width = tile + dotRadius }
        if let text = icon.countText { width = tile + pillGap + pillWidth(text) }
        return NSSize(width: ceil(width), height: height)
    }

    private static func pillWidth(_ text: String) -> CGFloat {
        let textWidth = (text as NSString).size(withAttributes: [.font: pillFont]).width
        return max(pillHeight, ceil(textWidth) + 6)
    }

    static func bitmap(for icon: MenuBarIcon, scale: Int) -> NSBitmapImageRep {
        let points = size(for: icon)
        let pixelWidth = Int(points.width) * scale
        let pixelHeight = Int(points.height) * scale
        let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Top-left origin, in points.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(icon, scale: CGFloat(scale), canvas: points)
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        bitmap.size = points
        return bitmap
    }

    private static func draw(_ icon: MenuBarIcon, scale: CGFloat, canvas: NSSize) {
        let tileTop = (height - tile) / 2
        let tileRect = NSRect(x: 0, y: tileTop, width: tile, height: tile)
        // Monochrome is a template: only the alpha counts, and macOS picks the color.
        let ink = NSColor.black.withAlphaComponent(icon.paused ? pausedInkAlpha : 1)
        if icon.monochrome {
            drawPot(origin: tileRect.origin, scale: scale, color: ink)
        } else {
            (icon.paused ? pausedTile : paprika).setFill()
            let radius: CGFloat = 3.5
            NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius).fill()
            drawPot(origin: tileRect.origin, scale: scale, color: icon.paused ? pausedPot : cream)
        }

        if let text = icon.countText {
            let width = pillWidth(text)
            let pill = NSRect(x: tile + pillGap, y: ((height - pillHeight) / 2).rounded(), width: width, height: pillHeight)
            (icon.monochrome ? ink : icon.paused ? pausedTile : paprika).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: NSColor.white]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2)
            let context = NSGraphicsContext.current
            context?.saveGraphicsState()
            // In a template the digits are cut out of the pill.
            if icon.monochrome { context?.cgContext.setBlendMode(.clear) }
            (text as NSString).draw(at: origin, withAttributes: attributes)
            context?.restoreGraphicsState()
        }

        if icon.updateDot {
            // A clear ring around the dot sets it off from the tile under it.
            let center = NSPoint(x: tile - 0.5, y: tileTop + dotRadius - 0.5)
            let context = NSGraphicsContext.current
            context?.saveGraphicsState()
            context?.compositingOperation = .clear
            circle(center, radius: dotRadius + dotRing).fill()
            context?.restoreGraphicsState()
            (icon.monochrome ? NSColor.black : updateBlue).setFill()
            circle(center, radius: dotRadius).fill()
        }
    }

    private static func circle(_ center: NSPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// The pot on the tile's pixel grid: 16 px at 1x, 32 px at 2x. Each scale has its own
    /// drawing, so every edge falls on a whole pixel.
    private static func drawPot(origin: NSPoint, scale: CGFloat, color: NSColor) {
        color.set()
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: origin.x + x / scale, y: origin.y + y / scale, width: width / scale, height: height / scale)
        }
        if scale < 2 {
            // Three straight wisps, the middle one taller and two pixels wide.
            NSBezierPath(rect: rect(4, 4, 1, 3)).fill()
            NSBezierPath(rect: rect(11, 4, 1, 3)).fill()
            NSBezierPath(rect: rect(7, 3, 2, 4)).fill()
            NSBezierPath(rect: rect(2, 8, 12, 2)).fill()
            bowl(rect(3, 9, 10, 5), radius: 2 / scale).fill()
            NSBezierPath(rect: rect(1, 10, 2, 2)).fill()
            NSBezierPath(rect: rect(13, 10, 2, 2)).fill()
            return
        }
        let steam = NSBezierPath()
        for (column, top) in [(CGFloat(11), CGFloat(7)), (16, 5.5), (21, 7)] {
            let bottom: CGFloat = 12.5
            let third = (bottom - top) / 3
            steam.move(to: NSPoint(x: origin.x + column / scale, y: origin.y + top / scale))
            steam.curve(
                to: NSPoint(x: origin.x + column / scale, y: origin.y + bottom / scale),
                controlPoint1: NSPoint(x: origin.x + (column - 1.6) / scale, y: origin.y + (top + third) / scale),
                controlPoint2: NSPoint(x: origin.x + (column + 1.6) / scale, y: origin.y + (top + 2 * third) / scale)
            )
        }
        steam.lineWidth = 2 / scale
        steam.lineCapStyle = .round
        steam.stroke()
        NSBezierPath(roundedRect: rect(4, 15, 24, 4), xRadius: 2 / scale, yRadius: 2 / scale).fill()
        bowl(rect(6, 17, 20, 11), radius: 6 / scale).fill()
        NSBezierPath(roundedRect: rect(2, 20, 4, 4), xRadius: 1.5 / scale, yRadius: 1.5 / scale).fill()
        NSBezierPath(roundedRect: rect(26, 20, 4, 4), xRadius: 1.5 / scale, yRadius: 1.5 / scale).fill()
    }

    /// The pot's body: square at the top, under the lid, and rounded at the bottom.
    private static func bowl(_ frame: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: frame.minX, y: frame.minY))
        path.line(to: NSPoint(x: frame.maxX, y: frame.minY))
        path.line(to: NSPoint(x: frame.maxX, y: frame.maxY - radius))
        path.appendArc(withCenter: NSPoint(x: frame.maxX - radius, y: frame.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: frame.minX + radius, y: frame.maxY))
        path.appendArc(withCenter: NSPoint(x: frame.minX + radius, y: frame.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        path.close()
        return path
    }
}

/// The menu as SwiftUI, for `stew snapshot`: an NSMenu cannot be drawn offscreen. It
/// follows the system menu's metrics and is built from the same entries.
struct MenuPreview: View {
    let entries: [MenuEntry]

    init(state: MenuBarState) {
        entries = state.entries(timeText: Coordinator.clockText)
    }

    /// A submenu on its own.
    init(entries: [MenuEntry]) {
        self.entries = entries
    }

    static let rowHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 11
    static let verticalPadding: CGFloat = 5

    /// Where the row of `entry` starts, from the top of the menu: to draw its submenu
    /// beside it.
    static func top(of entry: MenuEntry, in entries: [MenuEntry]) -> CGFloat {
        let above = entries.prefix { $0 != entry }
        return verticalPadding + above.reduce(0) { height, row in height + (row.isSeparator ? separatorHeight : rowHeight) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                if entry.isSeparator {
                    Divider().padding(.horizontal, 10).frame(height: Self.separatorHeight)
                } else {
                    HStack(spacing: 8) {
                        Text(entry.title)
                            .fixedSize()
                            .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                        Spacer(minLength: 16)
                        if let badge = entry.badge {
                            Text("\(badge)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        if entry.hasSubmenu {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .frame(height: Self.rowHeight)
                }
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .frame(minWidth: 240)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
    }
}

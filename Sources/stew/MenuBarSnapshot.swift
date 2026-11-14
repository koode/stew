import AppKit
import SwiftUI
import StewCore

/// Renders the menu bar item for `stew snapshot`: every icon state on a light and a dark
/// menu bar, plain and highlighted, at 1x and 2x, and the menu in a few states. It never
/// adds an item to the real menu bar.
enum MenuBarSnapshot {
    private static let states: [(String, MenuBarIcon)] = [
        ("normal", MenuBarIcon()),
        ("count", MenuBarIcon(count: 3)),
        ("count 12", MenuBarIcon(count: 12)),
        ("update", MenuBarIcon(updateDot: true)),
        ("count, update", MenuBarIcon(count: 2, updateDot: true)),
        ("paused", MenuBarIcon(paused: true)),
        ("paused, count", MenuBarIcon(count: 1, paused: true)),
    ]

    /// How much bigger the zoomed copy of a strip is, pixel for pixel.
    private static let zoom = 8

    static func render(to directory: String, write: (AnyView, Bool, String) -> Void) {
        for dark in [false, true] {
            for scale in [1, 2] {
                let strip = iconStrip(dark: dark, scale: scale)
                let name = "\(directory)/menubar-icons-\(dark ? "dark" : "light")@\(scale)x"
                save(strip, to: name + ".png")
                save(enlarged(strip, by: zoom / scale), to: name + "-zoom.png")
            }
        }
        let needs = [
            NeedsItem(id: "3f9a1c2e", created: Date(), session: SessionInfo(name: "release", cwd: "~/code/web-app"), needs: NeedsRequest(title: "Log in to npm")),
            NeedsItem(id: "7b2d4e9f", created: Date(), session: SessionInfo(name: "mobile-app", cwd: "~/code/mobile-app"), needs: NeedsRequest(title: "Approve the build in App Store Connect")),
        ]
        let menus: [(String, MenuBarState)] = [
            ("menubar-menu", MenuBarState()),
            ("menubar-menu-waiting", MenuBarState(openNeeds: needs, missedCount: 3, update: .ready("0.2.0"))),
            ("menubar-menu-paused", MenuBarState(openNeeds: Array(needs.prefix(1)), missedCount: 1, pause: .until(Date().addingTimeInterval(42 * 60)), update: .available("0.2.0"))),
            ("menubar-menu-paused-until-back", MenuBarState(pause: .untilBack)),
            ("menubar-menu-pausing", MenuBarState(pause: .startsAt(Date().addingTimeInterval(45)))),
            ("menubar-menu-homebrew", MenuBarState(update: .homebrew("0.2.0"))),
            ("menubar-menu-hidden-setting", MenuBarState(openNeeds: Array(needs.prefix(1)), showsAlways: false)),
        ]
        for (name, state) in menus {
            for dark in [false, true] {
                let path = "\(directory)/\(name)-\(dark ? "dark" : "light").png"
                write(AnyView(MenuPreview(state: state)), dark, path)
                print(path)
            }
        }
        // The Pause stew submenu open beside its entry, as macOS draws it.
        let entries = MenuBarState().entries(timeText: Coordinator.clockText)
        if let pauseEntry = entries.first(where: \.hasSubmenu) {
            let submenuTop = MenuPreview.top(of: pauseEntry, in: entries) - MenuPreview.verticalPadding
            for dark in [false, true] {
                let path = "\(directory)/menubar-menu-pause-submenu-\(dark ? "dark" : "light").png"
                let view = HStack(alignment: .top, spacing: -2) {
                    MenuPreview(entries: entries)
                    MenuPreview(entries: pauseEntry.submenu).padding(.top, submenuTop)
                }
                write(AnyView(view), dark, path)
                print(path)
            }
        }
    }

    /// A strip of menu bar per state: the item plain, then highlighted as when its menu is
    /// open, with the state's name under it. Drawn at `scale` pixels per point.
    private static func iconStrip(dark: Bool, scale: Int) -> NSBitmapImageRep {
        let barHeight: CGFloat = 24
        let labelHeight: CGFloat = 14
        let cellPadding: CGFloat = 10
        let cells = states.flatMap { name, icon in [(name, icon, false), (name + ", open", icon, true)] }
        let widths = cells.map { StatusIcon.size(for: $0.1).width + 2 * cellPadding }
        let labelFont = NSFont.systemFont(ofSize: 8)
        let labelWidths = cells.map { ($0.0 as NSString).size(withAttributes: [.font: labelFont]).width + 8 }
        let cellWidths = zip(widths, labelWidths).map { max($0, ceil($1)) }
        let width = cellWidths.reduce(0, +)
        let height = barHeight + labelHeight
        let context = CGContext(
            data: nil, width: Int(width) * scale, height: Int(height) * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: height * CGFloat(scale))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let bar = dark ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
        let page = dark ? NSColor(srgbRed: 0.2, green: 0.2, blue: 0.21, alpha: 1) : NSColor.white
        page.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        bar.setFill()
        NSRect(x: 0, y: 0, width: width, height: barHeight).fill()
        var left: CGFloat = 0
        for (index, cell) in cells.enumerated() {
            let (name, icon, open) = cell
            let cellWidth = cellWidths[index]
            let iconSize = StatusIcon.size(for: icon)
            let iconX = (left + (cellWidth - iconSize.width) / 2).rounded(.down)
            if open {
                // The highlight macOS draws behind an item whose menu is open.
                (dark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.1)).setFill()
                NSBezierPath(roundedRect: NSRect(x: iconX - 5, y: 2, width: iconSize.width + 10, height: barHeight - 4), xRadius: 5, yRadius: 5).fill()
            }
            let image = StatusIcon.image(for: icon)
            image.draw(in: NSRect(x: iconX, y: ((barHeight - iconSize.height) / 2).rounded(.down), width: iconSize.width, height: iconSize.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: dark ? NSColor(white: 0.75, alpha: 1) : NSColor(white: 0.35, alpha: 1)]
            let labelSize = (name as NSString).size(withAttributes: attributes)
            (name as NSString).draw(at: NSPoint(x: left + (cellWidth - labelSize.width) / 2, y: barHeight + 2), withAttributes: attributes)
            left += cellWidth
        }
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: context.makeImage()!)
    }

    /// The strip scaled up with each pixel kept square, to check the pixel grid.
    private static func enlarged(_ bitmap: NSBitmapImageRep, by factor: Int) -> NSBitmapImageRep {
        let width = bitmap.pixelsWide * factor
        let height = bitmap.pixelsHigh * factor
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .none
        context.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
        return NSBitmapImageRep(cgImage: context.makeImage()!)
    }

    private static func save(_ bitmap: NSBitmapImageRep, to path: String) {
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}

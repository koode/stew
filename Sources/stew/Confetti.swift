import AppKit
import QuartzCore

/// A window that can never take focus or clicks, so the burst never gets in the way.
private final class ConfettiPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A short burst of confetti over the spot where the panel was.
final class ConfettiController {
    private var windows: [NSWindow] = []

    static let duration: TimeInterval = 1.2
    private static let colors: [NSColor] = [.systemPink, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]

    /// Shows a burst around `frame`. Does nothing when the user asked macOS to reduce motion.
    func burst(around frame: NSRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Wider than the panel for the spread, and taller below it so pieces can fall.
        let spread: CGFloat = 120
        let fall: CGFloat = 320
        let windowFrame = NSRect(
            x: frame.minX - spread,
            y: frame.minY - fall,
            width: frame.width + 2 * spread,
            height: frame.height + fall + 40
        )
        let window = ConfettiPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: windowFrame.size))
        content.wantsLayer = true
        let emitter = CAEmitterLayer()
        emitter.frame = content.bounds
        // A line across the panel's top edge, so the pieces start where the panel was.
        emitter.emitterShape = .line
        emitter.emitterSize = CGSize(width: frame.width, height: 1)
        emitter.emitterPosition = CGPoint(x: content.bounds.midX, y: content.bounds.height - 40)
        emitter.emitterCells = Self.colors.map(Self.cell(color:))
        emitter.beginTime = CACurrentMediaTime()
        content.layer?.addSublayer(emitter)
        window.contentView = content

        window.orderFrontRegardless()
        windows.append(window)

        // Short emission, then let the pieces fall out before the window closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            emitter.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self, weak window] in
            guard let window else { return }
            window.orderOut(nil)
            window.close()
            self?.windows.removeAll { $0 === window }
        }
    }

    private static func cell(color: NSColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = piece(color: color)
        cell.birthRate = 70
        cell.lifetime = Float(duration)
        cell.velocity = 260
        cell.velocityRange = 120
        // Upward and outward first; gravity brings them down.
        cell.emissionLongitude = .pi / 2
        cell.emissionRange = .pi / 2.2
        cell.yAcceleration = -620
        cell.spin = 4
        cell.spinRange = 8
        cell.scale = 0.9
        cell.scaleRange = 0.4
        cell.alphaSpeed = -0.5
        return cell
    }

    private static func piece(color: NSColor) -> CGImage? {
        let size = NSSize(width: 9, height: 5)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

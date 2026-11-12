import AppKit
import SwiftUI
import StewCore

/// Borderless, non-activating: it floats over everything and never takes keyboard focus
/// unless the user opens the reply field.
final class StewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController {
    private let coordinator: Coordinator
    private let panel: StewPanel
    private let hosting: NSHostingView<RootView>
    private let hotkeys = HotkeyCenter()
    private var shownItemID: UUID?
    private var registeredSignature = ""
    private var previousApp: NSRunningApplication?
    private var focusedForText = false
    private var armedAt = Date.distantPast

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        panel = StewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: RootView(coordinator: coordinator, interactive: true))
        panel.contentView = hosting
    }

    func update() {
        // Let SwiftUI apply the change before measuring.
        DispatchQueue.main.async { [self] in apply() }
    }

    private func apply() {
        guard let item = coordinator.current else {
            hotkeys.unregisterAll()
            registeredSignature = ""
            shownItemID = nil
            leaveTextFocus()
            panel.orderOut(nil)
            return
        }
        let isNewItem = shownItemID != item.id
        shownItemID = item.id
        if isNewItem {
            armedAt = Date().addingTimeInterval(coordinator.config.armDelay)
        }
        registerHotkeys()
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if isNewItem || !panel.isVisible {
            panel.setFrame(defaultFrame(for: size), display: true)
        } else {
            // Grow and shrink from the top edge, so the header stays put.
            let frame = panel.frame
            panel.setFrame(NSRect(x: frame.maxX - size.width, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        if coordinator.textMode {
            enterTextFocus()
        } else {
            leaveTextFocus()
        }
    }

    private func registerHotkeys() {
        let signature = coordinator.bindingSignature
        guard signature != registeredSignature else { return }
        registeredSignature = signature
        let bindings: [(Shortcut, () -> Void)] = coordinator.activeBindings().map { shortcut, action, option in
            (shortcut, { [weak self, weak coordinator] in
                guard let self, Date() >= self.armedAt else { return }
                if let action { coordinator?.perform(action) }
                if let option { coordinator?.choose(option: option) }
            })
        }
        let failures = hotkeys.set(bindings)
        coordinator.setHotkeyFailures(failures.map(\.description))
        if !failures.isEmpty {
            Log.write("could not register \(failures.map(\.description).joined(separator: " ")); another app may own them")
        }
    }

    private func defaultFrame(for size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let margin: CGFloat = 14
        let x: CGFloat
        switch coordinator.config.position {
        case "top-center": x = visible.midX - size.width / 2
        case "top-left": x = visible.minX + margin
        default: x = visible.maxX - size.width - margin
        }
        return NSRect(x: x, y: visible.maxY - size.height - margin, width: size.width, height: size.height)
    }

    /// The reply field is the one place that takes focus, and only on request.
    private func enterTextFocus() {
        guard !focusedForText else { return }
        focusedForText = true
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    private func leaveTextFocus() {
        guard focusedForText else { return }
        focusedForText = false
        panel.resignKey()
        previousApp?.activate()
        previousApp = nil
    }
}

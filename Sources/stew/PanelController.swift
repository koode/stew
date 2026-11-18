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
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// True while stew itself moves the panel, so only the user's drags snap.
    private var placing = false
    private var dragCheck: DispatchWorkItem?
    /// A drag snapped the panel to `position` on `display` (a display UUID). The daemon saves
    /// both in the config, so later requests open there too.
    var onPlaced: ((_ position: String, _ display: String?) -> Void)?

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
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screensChanged()
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.panelMoved()
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// Where the panel is on screen, or nil while it is hidden.
    var visibleFrame: NSRect? { panel.isVisible ? panel.frame : nil }

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
        if isNewItem || !panel.isVisible {
            let screen = homeScreen()
            place(defaultFrame(for: fittedSize(on: screen), on: screen))
        } else {
            // Grow and shrink from the edges the spot is anchored to, so the header stays
            // put at the top, but never past the edge of the screen.
            let screen = currentScreen()
            let grown = PanelPlacement.resized(panel.frame, to: fittedSize(on: screen), position: coordinator.config.position)
            place(PanelPlacement.clamp(grown, into: screen.visibleFrame))
        }
        panel.orderFrontRegardless()
        if coordinator.textMode {
            enterTextFocus()
        } else {
            leaveTextFocus()
        }
    }

    private func registerHotkeys() {
        if coordinator.panelKeysSuspended {
            hotkeys.unregisterAll()
            registeredSignature = "suspended"
            return
        }
        let signature = coordinator.bindingSignature
        guard signature != registeredSignature else { return }
        registeredSignature = signature
        let bindings: [(Shortcut, () -> Void)] = coordinator.activeBindings().map { shortcut, panelAction in
            (shortcut, { [weak self, weak coordinator] in
                guard let self, Date() >= self.armedAt else { return }
                coordinator?.perform(panelAction)
            })
        }
        let failures = hotkeys.set(bindings)
        coordinator.setHotkeyFailures(failures)
        if !failures.isEmpty {
            Log.write("could not register \(failures.map(\.description).joined(separator: " ")); another app may own them")
        }
    }

    private var heightLimit: CGFloat?
    private let margin = PanelPlacement.margin

    /// The display the user dragged the panel to, while it is connected.
    private func rememberedScreen() -> NSScreen? {
        guard let display = coordinator.config.display else { return nil }
        return NSScreen.screens.first { $0.displayUUID == display }
    }

    /// Where a request opens: the remembered display, else the display with the pointer.
    private func homeScreen() -> NSScreen {
        if let screen = rememberedScreen() { return screen }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The display the panel is on while it shows, else where the next one opens.
    private func currentScreen() -> NSScreen {
        if panel.isVisible, let screen = panel.screen { return screen }
        return homeScreen()
    }

    private func place(_ frame: NSRect, animate: Bool = false) {
        placing = true
        panel.setFrame(frame, display: true, animate: animate)
        placing = false
    }

    /// Natural height first. Taller than the screen: cap it and let the panel scroll.
    private func fittedSize(on screen: NSScreen) -> NSSize {
        if heightLimit != nil {
            heightLimit = nil
            hosting.rootView = RootView(coordinator: coordinator, interactive: true)
        }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        let maximum = (screen.visibleFrame.height - 2 * margin).rounded(.down)
        if size.height > maximum {
            heightLimit = maximum
            hosting.rootView = RootView(coordinator: coordinator, interactive: true, heightLimit: maximum)
            hosting.layoutSubtreeIfNeeded()
            size = hosting.fittingSize
        }
        return size
    }

    private func defaultFrame(for size: NSSize, on screen: NSScreen) -> NSRect {
        PanelPlacement.corner(coordinator.config.position, size: size, visible: screen.visibleFrame)
    }

    /// A display came, went, or changed its resolution or arrangement. The old frame can now
    /// be partly off screen or on no screen at all, so the panel goes back to its spot: on the
    /// remembered display when it is connected, else on the display it is on (or the one with
    /// the pointer), measured for that display.
    private func screensChanged() {
        guard panel.isVisible, coordinator.current != nil, !NSScreen.screens.isEmpty else { return }
        let screen = rememberedScreen() ?? panel.screen ?? homeScreen()
        place(defaultFrame(for: fittedSize(on: screen), on: screen))
    }

    /// The user drags the panel. Once the mouse button is up, it snaps to the nearest spot on
    /// the display it was let go on.
    private func panelMoved() {
        guard !placing, panel.isVisible else { return }
        scheduleDragCheck()
    }

    private func scheduleDragCheck() {
        dragCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.settleDrag() }
        dragCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: check)
    }

    private func settleDrag() {
        guard panel.isVisible else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            scheduleDragCheck()
            return
        }
        guard let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) else { return }
        let position = PanelPlacement.nearest(to: panel.frame, in: screen.visibleFrame)
        place(PanelPlacement.corner(position, size: panel.frame.size, visible: screen.visibleFrame), animate: true)
        onPlaced?(position, screen.displayUUID)
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

extension NSScreen {
    /// Stays the same for a display across restarts and reconnects, unlike its index.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

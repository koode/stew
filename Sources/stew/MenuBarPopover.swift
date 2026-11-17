import AppKit
import Combine
import SwiftUI
import StewCore

/// What the menu bar popover shows, and what its buttons do. Its list of requests and
/// the preview beside it are a `HistoryModel` of their own.
final class MenuBarPopoverModel: ObservableObject {
    @Published var state = MenuBarState()
    let history = HistoryModel()
    var onOpenNeeds: (String) -> Void = { _ in }
    var onSettings: () -> Void = {}
    var onPause: (PauseChoice) -> Void = { _ in }
    var onResume: () -> Void = {}
    var onUpdate: () -> Void = {}
    /// Marks the missed requests seen and returns when they were seen before.
    var onSeen: () -> Date? = { nil }
    private var markedSeen = false
    private var filterWatch: AnyCancellable?

    init() {
        filterWatch = history.$missedOnly.dropFirst().sink { [weak self] _ in
            // Published before the change lands: check once it has.
            DispatchQueue.main.async { self?.markSeenIfShown() }
        }
    }

    var content: MenuBarPopoverContent {
        MenuBarPopoverContent(state: state, entries: history.entries, missedOnly: history.missedOnly)
    }

    /// The popover opens: fresh history, `entryID` or else the newest request selected,
    /// and the missed requests in its list count as seen.
    func opened(missedOnly: Bool, select entryID: UUID? = nil) {
        markedSeen = false
        history.open(missedOnly: missedOnly, select: entryID)
        markSeenIfShown()
    }

    func showSample(state: MenuBarState, entries: [HistoryEntry], mailbox: LateMailbox = LateMailbox(), missedOnly: Bool = false, selection: UUID? = nil, unseen: Set<UUID> = []) {
        self.state = state
        markedSeen = true
        history.showSample(entries, missedOnly: missedOnly, mailbox: mailbox, selection: selection, unseen: unseen)
    }

    private func markSeenIfShown() {
        guard !markedSeen, content.marksMissedSeen else { return }
        markedSeen = true
        history.markUnseen(since: onSeen())
    }

    /// The menu's line for the waiting update, such as "stew 0.2.0 is ready, restart to update".
    var updateTitle: String? {
        state.entries(timeText: Coordinator.clockText).first { $0.action == .update }?.title
    }
}

/// Left-click on the menu bar item: what waits on the user and every finished request
/// on the left, the selected request on the right as the panel showed it, and the pause
/// and Settings in the header. Right-click opens the menu.
struct MenuBarPopoverView: View {
    @ObservedObject var model: MenuBarPopoverModel
    @ObservedObject private var history: HistoryModel
    /// Closes the popover before a button opens a window or the panel.
    var dismiss: () -> Void = {}
    @State private var hovered: String?

    init(model: MenuBarPopoverModel, dismiss: @escaping () -> Void = {}) {
        self.model = model
        history = model.history
        self.dismiss = dismiss
    }

    static let listWidth: CGFloat = 320
    /// The widest panel, for a call auto mode blocked, beside the preview's inset.
    static let previewWidth: CGFloat = 560 + 2 * HistoryPreviewPane.inset
    static let width: CGFloat = listWidth + 1 + previewWidth
    /// The list and the preview scroll within it.
    static let bodyHeight: CGFloat = 520

    var body: some View {
        let content = model.content
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                HistoryList(model: history) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !content.needs.isEmpty {
                            needsSection(content.needs)
                        }
                        HistoryListHeader(model: history)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    if content.history.isEmpty {
                        emptyList
                    }
                }
                .frame(width: Self.listWidth)
                .background(Color.primary.opacity(0.035))
                Divider()
                HistoryDetail(model: history)
                    .frame(width: Self.previewWidth)
            }
            .frame(height: Self.bodyHeight)
        }
        .frame(width: Self.width)
        // Opaque, so the desktop behind the popover never shows through and the text
        // keeps the contrast it was checked for.
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.paprika)
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in history.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: StatusIcon.image(for: MenuBarIcon(paused: model.state.pause?.isPaused ?? false)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("stew").font(.system(size: 13, weight: .semibold))
                    if let pause = model.state.pause {
                        // "Pausing in 0:45…" counts down each second.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(pause.title(now: context.date, timeText: Coordinator.clockText))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(Ink.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let pause = model.state.pause {
                    Button { model.onResume() } label: {
                        HeaderControl(title: pause.isPaused ? "Resume" : "Cancel pause")
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                } else {
                    // The same choices as the menu's Pause stew submenu.
                    Menu {
                        ForEach(model.state.pauseChoices, id: \.self) { choice in
                            Button(choice.title(now: Date(), calendar: .current, timeText: Coordinator.clockText)) {
                                model.onPause(choice)
                            }
                        }
                    } label: {
                        HeaderControl(title: "Pause stew…", menu: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .focusEffectDisabled()
                    .fixedSize()
                }
                Button {
                    dismiss()
                    model.onSettings()
                } label: {
                    HeaderControl(title: "Settings")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            .controlSize(.small)
            if let title = model.updateTitle {
                Button {
                    dismiss()
                    model.onUpdate()
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(Tone.blue.color).frame(width: 7, height: 7)
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tone.blue.color.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func needsSection(_ needs: [NeedsItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: NeedsBook.countText(needs.count))
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            ForEach(needs, id: \.id) { item in
                Button {
                    dismiss()
                    model.onOpenNeeds(item.id)
                } label: {
                    // The icon takes the width of the history rows' dot, so the titles
                    // of both lists start at the same x.
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: NeedsStyle.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NeedsStyle.tint)
                            .frame(width: 12)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.needs.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(item.session.name).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 4)
                    .background(ListRowSelection(selected: hovered == item.id, focused: false))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in hover(item.id, inside) }
                .help(item.session.cwd ?? item.session.name)
            }
        }
        .padding(.horizontal, -4)
    }

    private var emptyList: some View {
        EmptyState(
            symbol: history.missedOnly ? "clock.badge.exclamationmark" : "clock",
            title: history.missedOnly ? "No missed requests" : "No requests yet",
            message: history.missedOnly
                ? "Requests that run out of time while nobody answers, and secrets you chose to enter later, show here."
                : "Permission requests, questions and notifications show here once they finish."
        )
        .padding(.horizontal, 12)
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }
}

/// Shows the popover under the menu bar item. Opening it does not activate stew: the
/// user's app keeps the keyboard, and the floating panel keeps its rule of never taking
/// it. A click in the popover gives it the keyboard, for the list's arrow keys and,
/// after a click in the preview, the panel's keys; closing it hands the keyboard back.
/// A click anywhere else closes it.
final class MenuBarPopoverController: NSObject, NSPopoverDelegate {
    let model = MenuBarPopoverModel()
    private let popover = NSPopover()
    private var outsideClicks: Any?
    private var insideClicks: Any?
    /// The app that had the keyboard before a click in the popover took it.
    private var previousApp: NSRunningApplication?
    /// Told after the popover closed.
    var onClose: () -> Void = {}

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(model: model) { [weak self] in self?.close() })
    }

    var isShown: Bool { popover.isShown }

    private var window: NSWindow? { popover.contentViewController?.view.window }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else {
            show(from: button, missedOnly: false)
        }
    }

    /// Opens the popover, or keeps it open, on the requests, only the missed ones when
    /// `missedOnly`, with `entryID` or else the newest selected.
    func show(from button: NSStatusBarButton, missedOnly: Bool, select entryID: UUID? = nil) {
        model.opened(missedOnly: missedOnly, select: entryID)
        guard !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        model.history.startKeys()
        // A transient popover of an app that is not active does not see clicks in other
        // apps; a global monitor does, without any permission for mouse clicks.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        insideClicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.takeKeyboard(for: event)
            return event
        }
    }

    /// A click in the popover makes it the key window, so its keys reach it.
    private func takeKeyboard(for event: NSEvent) {
        guard let window, event.window === window, !window.isKeyWindow else { return }
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKey()
        // Becoming key would focus the first control (Pause stew) and draw its focus ring;
        // the click itself still focuses whatever it lands on.
        window.makeFirstResponder(nil)
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
        stopWatching()
    }

    func popoverDidClose(_ notification: Notification) {
        stopWatching()
        handBackKeyboard()
        onClose()
    }

    /// The app that had the keyboard before a click in the popover gets it back,
    /// unless a stew window, such as Settings, opened meanwhile.
    private func handBackKeyboard() {
        guard let previousApp else { return }
        self.previousApp = nil
        DispatchQueue.main.async {
            guard NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            previousApp.activate()
        }
    }

    private func stopWatching() {
        for monitor in [outsideClicks, insideClicks].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        outsideClicks = nil
        insideClicks = nil
        model.history.stopKeys()
    }
}

/// A button in the popover header: a label on the raised capsule of the history filter,
/// with a chevron when it opens a menu. No focus ring: the first control would otherwise
/// get one as soon as the popover opens.
private struct HeaderControl: View {
    let title: String
    var menu = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            if menu {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(GlassCapsule())
        .contentShape(Capsule())
    }
}

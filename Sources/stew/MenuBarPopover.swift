import AppKit
import SwiftUI
import StewCore

/// What the menu bar popover shows, and what its buttons do.
final class MenuBarPopoverModel: ObservableObject {
    @Published var state = MenuBarState()
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var missedOnly = false {
        didSet { if missedOnly != oldValue { markSeenIfShown() } }
    }
    /// Missed requests that were new when the popover opened: they keep a dot.
    @Published private(set) var unseen: Set<UUID> = []
    var onOpenNeeds: (String) -> Void = { _ in }
    var onOpenEntry: (UUID) -> Void = { _ in }
    var onHistory: () -> Void = {}
    var onSettings: () -> Void = {}
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onUpdate: () -> Void = {}
    /// Marks the missed requests seen and returns when they were seen before.
    var onSeen: () -> Date? = { nil }
    private var markedSeen = false

    var content: MenuBarPopoverContent {
        MenuBarPopoverContent(state: state, entries: entries, missedOnly: missedOnly)
    }

    /// The popover opens: fresh history, and the missed requests in its list count as seen.
    func opened(entries: [HistoryEntry]) {
        self.entries = entries
        unseen = []
        markedSeen = false
        markSeenIfShown()
    }

    func showSample(state: MenuBarState, entries: [HistoryEntry], missedOnly: Bool = false, unseen: Set<UUID> = []) {
        self.state = state
        self.entries = entries
        self.missedOnly = missedOnly
        self.unseen = unseen
        markedSeen = true
    }

    private func markSeenIfShown() {
        guard !markedSeen, content.marksMissedSeen else { return }
        markedSeen = true
        unseen = History.unseenMissedIDs(entries, seenAt: onSeen())
    }

    /// The menu's line for the waiting update, such as "stew 0.2.0 is ready, restart to update".
    var updateTitle: String? {
        state.entries(timeText: Coordinator.clockText).first { $0.action == .update }?.title
    }
}

/// Left-click on the menu bar item: what waits on the user, the recent requests, and
/// History, Settings and the pause. Right-click opens the menu.
struct MenuBarPopoverView: View {
    @ObservedObject var model: MenuBarPopoverModel
    /// Closes the popover before a button opens a window or the panel.
    var dismiss: () -> Void = {}
    @State private var hovered: String?

    static let width: CGFloat = 360

    var body: some View {
        let content = model.content
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !content.needs.isEmpty {
                        needsSection(content.needs)
                    }
                    historySection(content)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
        }
        .frame(width: Self.width)
        .tint(Brand.paprika)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: StatusIcon.image(for: MenuBarIcon(paused: model.state.pausedUntil != nil)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("stew").font(.system(size: 13, weight: .semibold))
                    if let until = model.state.pausedUntil {
                        Text("Paused until \(Coordinator.clockText(until))")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if model.state.pausedUntil != nil {
                    Button("Resume") { model.onResume() }
                        .controlSize(.small)
                }
            }
            if let title = model.updateTitle {
                Button {
                    dismiss()
                    model.onUpdate()
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(Color.blue).frame(width: 7, height: 7)
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.blue.opacity(0.12)))
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
                            Text(item.session.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
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
    }

    private func historySection(_ content: MenuBarPopoverContent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(text: "Recent requests")
                Spacer()
                HistoryFilterPicker(missedOnly: $model.missedOnly)
                    .controlSize(.small)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            if content.history.isEmpty {
                EmptyState(
                    symbol: model.missedOnly ? "clock.badge.exclamationmark" : "clock",
                    title: model.missedOnly ? "No missed requests" : "No requests yet",
                    message: model.missedOnly
                        ? "Requests that run out of time while nobody answers show here."
                        : "Finished requests show here."
                )
            } else {
                ForEach(content.history) { entry in
                    Button {
                        dismiss()
                        model.onOpenEntry(entry.id)
                    } label: {
                        HistoryRow(entry: entry, unseen: model.unseen.contains(entry.id))
                            .background(ListRowSelection(selected: hovered == entry.id.uuidString, focused: false))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in hover(entry.id.uuidString, inside) }
                }
                if content.historyTotal > content.history.count {
                    Text("\(content.historyTotal - content.history.count) more in History")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("History") {
                dismiss()
                model.onHistory()
            }
            Button("Settings") {
                dismiss()
                model.onSettings()
            }
            Spacer()
            if model.state.pausedUntil == nil {
                Button("Pause for 1 hour") { model.onPause() }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }
}

/// Shows the popover under the menu bar item. It does not activate stew: the user's app
/// keeps the keyboard, and the floating panel keeps its rule of never taking it. A
/// click anywhere else closes it.
final class MenuBarPopoverController: NSObject, NSPopoverDelegate {
    let model = MenuBarPopoverModel()
    private let popover = NSPopover()
    private var outsideClicks: Any?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(model: model) { [weak self] in self?.close() })
    }

    var isShown: Bool { popover.isShown }

    func toggle(from button: NSStatusBarButton, entries: [HistoryEntry]) {
        if popover.isShown {
            close()
            return
        }
        model.opened(entries: entries)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A transient popover of an app that is not active does not see clicks in other
        // apps; a global monitor does, without any permission for mouse clicks.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
        stopWatching()
    }

    func popoverDidClose(_ notification: Notification) {
        stopWatching()
    }

    private func stopWatching() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }
}

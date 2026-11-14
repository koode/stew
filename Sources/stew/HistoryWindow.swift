import AppKit
import SwiftUI
import StewCore

/// Every finished request, newest first, in a list, and the selected one beside it as
/// the panel showed it: the History tab and the menu bar popover each have one. The
/// newest request in the filter is selected unless the user picks another; selecting
/// one never answers it.
final class HistoryModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    /// Switching the filter selects the newest request it shows.
    @Published var missedOnly = false {
        didSet { if missedOnly != oldValue { selection = visible.first?.id } }
    }
    @Published var selection: HistoryEntry.ID? {
        didSet {
            guard selection != oldValue else { return }
            if let selection { unseen.remove(selection) }
            message = nil
            rebuildPreview()
        }
    }
    @Published private(set) var message: HistoryMessage?
    @Published private(set) var keepDays = History.defaultKeepDays
    /// Timed-out requests that can still be answered, and the late answers given.
    @Published private(set) var mailbox = LateMailbox()
    /// Missed requests that were new when History opened: they keep a dot until selected.
    @Published private(set) var unseen: Set<UUID> = []
    /// The selected request, drawn with the panel's views.
    @Published private(set) var preview: HistoryPreview? {
        didSet { updateKeyOwnership() }
    }
    /// A late answer from the preview. False when it is too late.
    var onLateAnswer: ((UUID, StewResponse) -> Bool)?
    /// True after a click in the preview, false after one in the list: only while the
    /// preview has the keyboard do the panel's keys answer it.
    @Published var keysInPreview = false {
        didSet { updateKeyOwnership() }
    }
    /// Told when the preview takes the panel's keys and when it lets go of them.
    var onPreviewKeys: ((Bool) -> Void)?
    private var ownsKeys = false
    private var keyWindowObservers: [NSObjectProtocol] = []
    /// Counts clicks in the preview, so the list gives up the keyboard.
    @Published private(set) var previewClicks = 0
    /// The list and the preview on screen, to tell which one a click landed in.
    weak var listArea: NSView?
    weak var previewArea: NSView?
    /// The window the list is in. Keys typed in another window never reach the preview.
    var window: NSWindow? { listArea?.window ?? previewArea?.window }
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var keyLayout: [Character: UInt16] = [:]
    /// Sample entries for `stew snapshot`: reloading leaves them alone.
    private var isSample = false

    func showSample(_ entries: [HistoryEntry], missedOnly: Bool = false, mailbox: LateMailbox = LateMailbox(), selection: UUID? = nil, unseen: Set<UUID> = []) {
        isSample = true
        self.entries = entries
        self.mailbox = mailbox
        self.missedOnly = missedOnly
        self.selection = selection ?? visible.first?.id
        // The selected request is seen, as when the user opens it.
        self.unseen = unseen.filter { $0 != self.selection }
        rebuildPreview()
    }

    var visible: [HistoryEntry] { History.filtered(entries, missedOnly: missedOnly) }
    var selected: HistoryEntry? { entries.first { $0.id == selection } }
    /// How many requests the Missed filter shows.
    var missedCount: Int { History.filtered(entries, missedOnly: true).count }

    func reload() {
        guard !isSample else { return }
        keepDays = loadConfig().0.historyDays
        entries = HistoryStore.readFile()
        mailbox = LateAnswerFile.read()
        unseen = unseen.filter { id in entries.contains { $0.id == id && $0.late == nil } }
        keepSelectionVisible()
        rebuildPreview()
    }

    /// The list shows again, as History's tab or the popover opens: fresh entries, the
    /// filter asked for, and `entryID` or else the newest request selected. The keyboard
    /// starts in the list, so no key answers the preview before a click in it.
    func open(missedOnly: Bool, select entryID: UUID? = nil) {
        reload()
        keysInPreview = false
        message = nil
        self.missedOnly = missedOnly
        select(entryID)
    }

    /// History showed. `seenBefore` is when it last showed: missed requests since then
    /// get the unseen dot, until selected.
    func markUnseen(since seenBefore: Date?) {
        reload()
        unseen.formUnion(History.unseenMissedIDs(entries, seenAt: seenBefore))
        if let selection { unseen.remove(selection) }
    }

    /// Removes every request from the history, in the daemon, then shows the empty list.
    var onClear: (() -> Void)?

    func clear() {
        onClear?()
        unseen = []
        message = nil
        reload()
    }

    /// Selects `entryID`, showing every request if the filter hides it. Nil selects the
    /// newest request in the filter.
    func select(_ entryID: UUID?) {
        guard let entryID else {
            selection = visible.first?.id
            return
        }
        if !visible.contains(where: { $0.id == entryID }) { missedOnly = false }
        selection = entryID
    }

    /// Up and down in the list. Nothing selected: down picks the first.
    func moveSelection(by offset: Int) {
        let ids = visible.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = offset > 0 ? ids.first : ids.last
            return
        }
        selection = ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// The user's pick stays while it is in the list; when it leaves, or nothing is
    /// selected, the newest request is.
    private func keepSelectionVisible() {
        selection = History.keptSelection(selection, in: visible)
    }

    private func rebuildPreview() {
        guard let entry = selected else {
            preview = nil
            return
        }
        let waiting = entry.late == nil && entry.answerableLater ? mailbox.waiting(entry.id, now: Date()) : nil
        if let preview, preview.signature == HistoryPreview.signature(entry, live: waiting != nil) { return }
        preview = HistoryPreview(entry: entry, waiting: waiting) { [weak self] entryID, response in
            self?.answerLate(entryID, response) ?? false
        }
    }

    private func answerLate(_ entryID: UUID, _ response: StewResponse) -> Bool {
        let stored = onLateAnswer?(entryID, response) ?? false
        message = stored
            ? HistoryMessage(.success, "Claude gets your answer at its next step.")
            : HistoryMessage(.error, "This request can no longer be answered: it timed out more than a day ago.")
        // The coordinator dropped the item: build the preview again, with the outcome.
        preview = nil
        reload()
        return stored
    }

    /// Where a late answer is: waiting for the session's next step, or delivered.
    func deliveryText(_ entry: HistoryEntry) -> String? {
        guard entry.late != nil else { return nil }
        guard let answer = mailbox.answer(entry.id) else {
            return "No longer tracked: answers are kept for a day."
        }
        if let delivered = answer.delivered {
            return "Delivered \(SettingsDate.text(delivered))\(answer.deliveredBy.map { ", at \($0)" } ?? "")."
        }
        return "Waiting for the session's next step."
    }

    /// "Allow next time…" on a missed auto mode block: the same grants as the panel's
    /// "Allow more…", for the project the call came from.
    func allow(_ scope: GrantChoice.Scope, _ duration: GrantChoice.Duration, for blocked: BlockedCall) {
        do {
            try GrantFile.update { grants in
                try Hooks.apply(GrantChoice(scope: scope, duration: duration), toolName: blocked.toolName, projectRoot: blocked.projectRoot, grants: &grants)
            }
            let project = URL(fileURLWithPath: blocked.projectRoot).lastPathComponent
            message = HistoryMessage(.success, duration == .always ? "Allowed in \(project) from now on." : "Allowed in \(project) for 1 hour.")
        } catch {
            message = HistoryMessage(.error, "Could not allow it: \(error)")
        }
    }

    /// The panel's keys answer the preview, only while History's window is key and the
    /// preview has the keyboard. The list's keys only move the selection.
    func startKeys() {
        guard keyMonitor == nil else { return }
        keyLayout = KeyCodes.currentLayoutMap()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.keysInPreview, let window = self.window, event.window === window, window.isKeyWindow,
                  let preview = self.preview, preview.perform(event, layout: self.keyLayout) else { return event }
            return nil
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if Self.area(self.previewArea, contains: event) {
                self.keysInPreview = true
                self.previewClicks += 1
            } else if Self.area(self.listArea, contains: event) {
                self.keysInPreview = false
            }
            return event
        }
        keyWindowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateKeyOwnership() }
        }
    }

    private static func area(_ area: NSView?, contains event: NSEvent) -> Bool {
        guard let area, area.window === event.window else { return false }
        return area.bounds.contains(area.convert(event.locationInWindow, from: nil))
    }

    /// The preview has the panel's keys while it was clicked last, shows a request, and
    /// its window is key.
    private func updateKeyOwnership() {
        let owns = keysInPreview && preview != nil && window?.isKeyWindow == true
        guard owns != ownsKeys else { return }
        ownsKeys = owns
        onPreviewKeys?(owns)
    }

    func stopKeys() {
        keyWindowObservers.forEach(NotificationCenter.default.removeObserver)
        keyWindowObservers = []
        for monitor in [keyMonitor, clickMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        clickMonitor = nil
        keysInPreview = false
    }
}

/// A line under the preview about something that just happened.
struct HistoryMessage: Equatable {
    let tone: Notice.Tone
    let text: String

    init(_ tone: Notice.Tone, _ text: String) {
        self.tone = tone
        self.text = text
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        SettingsPane(
            tab: .history,
            subtitle: "Requests from the last \(model.keepDays) days. Missed ones ran out of time while nobody answered, or are secrets you chose to enter later.",
            fullWidth: true
        ) {
            HSplitView {
                sidebar
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
                HistoryDetail(model: model)
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) { Divider() }
            .padding(.top, 12)
        }
        .onAppear {
            model.reload()
            model.startKeys()
        }
        .onDisappear { model.stopKeys() }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in model.reload() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HistoryListHeader(model: model)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if model.visible.isEmpty {
                emptyList
            } else {
                HistoryList(model: model)
            }
        }
        .background(Color.primary.opacity(0.035))
    }

    private var emptyList: some View {
        EmptyState(
            symbol: model.missedOnly ? "clock.badge.exclamationmark" : "clock",
            title: model.missedOnly ? "No missed requests" : "No requests yet",
            message: model.missedOnly
                ? "Requests that run out of time while nobody answers, and secrets you chose to enter later, show here."
                : "Permission requests, questions and notifications show here once they finish."
        )
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }
}

/// The list of requests, in History and in the menu bar popover: a click or up and down
/// select one. Plain keys only move the selection; they never answer anything. What
/// `header` holds scrolls with the rows, above them.
struct HistoryList<Header: View>: View {
    @ObservedObject var model: HistoryModel
    @ViewBuilder var header: Header
    @FocusState private var listFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    LazyVStack(spacing: 2) {
                        ForEach(model.visible) { entry in
                            HistoryRow(entry: entry, unseen: model.unseen.contains(entry.id))
                                .background(ListRowSelection(selected: entry.id == model.selection, focused: listFocused))
                                .id(entry.id)
                                .onTapGesture {
                                    listFocused = true
                                    model.selection = entry.id
                                }
                        }
                    }
                }
                .padding(6)
            }
            .background(AreaReader { area in model.listArea = area })
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: model.moveSelection(by: -1)
                case .down: model.moveSelection(by: 1)
                default: break
                }
            }
            .onChange(of: model.selection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selection) }
            }
            .onAppear {
                // Opened on a request further down, such as one asked for by id.
                if let selection = model.selection { proxy.scrollTo(selection) }
            }
            .onChange(of: listFocused) { _, focused in
                if focused { model.keysInPreview = false }
            }
            .onChange(of: model.previewClicks) {
                // A click in the preview takes the keyboard from the list, so its
                // selection dims, as in Mail.
                listFocused = false
            }
        }
    }
}

extension HistoryList where Header == EmptyView {
    init(model: HistoryModel) {
        self.init(model: model, header: { EmptyView() })
    }
}

/// The selected request beside the list, as the panel showed it.
struct HistoryDetail: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        if let entry = model.selected, let preview = model.preview, preview.entryID == entry.id {
            HistoryPreviewPane(model: model, entry: entry, preview: preview, focused: model.keysInPreview)
                .id(preview.signature)
                .background(AreaReader { area in model.previewArea = area })
        } else {
            EmptyState(
                symbol: "rectangle.on.rectangle",
                title: "No request selected",
                message: "Select a request to see it as the panel showed it. One that timed out can still be answered from here."
            )
            .opacity(model.visible.isEmpty ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

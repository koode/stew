import AppKit
import SwiftUI
import StewCore

/// The History tab: every finished request, newest first, in a list on the left, and
/// the selected one on the right as the panel showed it.
final class HistoryModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var missedOnly = false {
        didSet { if missedOnly != oldValue { keepSelectionVisible() } }
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
    /// Where the list and the preview are, in the window's content view.
    var listFrame: CGRect = .zero
    var previewFrame: CGRect = .zero
    /// The window History is in. Keys typed in another window never reach the preview.
    weak var window: NSWindow?
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
        self.selection = selection
        self.unseen = unseen
        rebuildPreview()
    }

    var visible: [HistoryEntry] { History.filtered(entries, missedOnly: missedOnly) }
    var selected: HistoryEntry? { entries.first { $0.id == selection } }

    func reload() {
        guard !isSample else { return }
        keepDays = loadConfig().0.historyDays
        entries = HistoryStore.readFile()
        mailbox = LateAnswerFile.read()
        unseen = unseen.filter { id in entries.contains { $0.id == id && $0.late == nil } }
        keepSelectionVisible()
        rebuildPreview()
    }

    /// History showed. `seenBefore` is when it last showed: missed requests since then
    /// get the unseen dot, until selected.
    func markUnseen(since seenBefore: Date?) {
        reload()
        unseen.formUnion(History.unseenMissedIDs(entries, seenAt: seenBefore))
        if let selection { unseen.remove(selection) }
    }

    /// Selects `entryID`, showing every request if the filter hides it.
    func select(_ entryID: UUID?) {
        if let entryID, !visible.contains(where: { $0.id == entryID }) { missedOnly = false }
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

    private func keepSelectionVisible() {
        if let selection, !visible.contains(where: { $0.id == selection }) { self.selection = nil }
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
            guard let self, let window = self.window, event.window === window,
                  let point = window.contentView?.convert(event.locationInWindow, from: nil) else { return event }
            if self.previewFrame.contains(point) {
                self.keysInPreview = true
                self.previewClicks += 1
            } else if self.listFrame.contains(point) {
                self.keysInPreview = false
            }
            return event
        }
        keyWindowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateKeyOwnership() }
        }
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
    @FocusState private var focus: HistoryFocus?

    private enum HistoryFocus: Hashable {
        case list
    }

    var body: some View {
        SettingsPane(
            tab: .history,
            subtitle: "Requests from the last \(model.keepDays) days. Missed ones ran out of time while nobody answered, or are secrets you chose to enter later."
        ) {
            HSplitView {
                sidebar
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
                detail
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) { Divider() }
            .padding(.top, 12)
        }
        .background(WindowReader { window in model.window = window })
        .onAppear {
            model.reload()
            model.startKeys()
        }
        .onDisappear { model.stopKeys() }
        .onChange(of: focus) { _, newFocus in
            if newFocus == .list { model.keysInPreview = false }
        }
        .onChange(of: model.previewClicks) {
            // A click in the preview takes the keyboard from the list, so its
            // selection dims, as in Mail.
            if focus == .list { focus = nil }
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in model.reload() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HistoryFilterPicker(missedOnly: $model.missedOnly)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            Divider()
            if model.visible.isEmpty {
                emptyList
            } else {
                list
            }
        }
        .background(Color.primary.opacity(0.035))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.visible) { entry in
                        HistoryRow(entry: entry, unseen: model.unseen.contains(entry.id))
                            .background(ListRowSelection(selected: entry.id == model.selection, focused: focus == .list))
                            .id(entry.id)
                            .onTapGesture {
                                focus = .list
                                model.selection = entry.id
                            }
                    }
                }
                .padding(6)
            }
            .onGeometryChange(for: CGRect.self) { geometry in geometry.frame(in: .global) } action: { frame in model.listFrame = frame }
            .focusable()
            .focused($focus, equals: .list)
            .focusEffectDisabled()
            // Plain keys only move the selection; they never answer anything.
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
        }
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

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selected, let preview = model.preview, preview.entryID == entry.id {
            HistoryPreviewPane(model: model, entry: entry, preview: preview, focused: model.keysInPreview)
                .id(preview.signature)
                .onGeometryChange(for: CGRect.self) { geometry in geometry.frame(in: .global) } action: { frame in model.previewFrame = frame }
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

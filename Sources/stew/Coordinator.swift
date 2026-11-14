import AppKit
import Foundation
import StewCore

enum RiskState: Equatable {
    case off
    case checking
    case done(RiskAssessment)
    case failed(String)
    /// Claude Code's auto mode already blocked the call; this is its real verdict.
    case blocked(BlockedCall)

    var assessment: RiskAssessment? {
        if case .done(let assessment) = self { return assessment }
        return nil
    }
}

/// One request on screen or waiting for its turn.
final class Item: ObservableObject, Identifiable {
    let id = UUID()
    let request: StewRequest
    var connection: Connection?
    let received = Date()
    /// Seconds the user gets once the item is at the front of the panel. Nil: no limit.
    var timeLimit: Double?
    /// The limit plus every extension, for the note Claude gets on timeout.
    var grantedSeconds: Double = 0
    /// Running clock. Nil while waiting behind another request or while paused.
    @Published var deadline: Date?
    /// Time left, kept while the clock is paused for typing a note or picking a grant.
    @Published var pausedRemaining: TimeInterval?
    var timer: DispatchWorkItem?
    /// Open on a paired phone: the clock pauses while the user reads it there.
    @Published var viewing: ViewingPause?
    /// Fires when the viewing pause ends, to resume the clock or time out at the cap.
    var viewingTimer: DispatchWorkItem?

    /// The caller's hard ceiling, such as Claude Code's hook timeout.
    var latestDeadline: Date? { request.maxWait.map { received.addingTimeInterval($0) } }

    func capped(_ date: Date) -> Date {
        latestDeadline.map { min(date, $0) } ?? date
    }
    @Published var flow: QuestionFlow?
    /// Why Submit did not send the answers: the question that still needs one. Cleared by
    /// the next choice or move.
    @Published var questionNotice: String?
    @Published var risk: RiskState = .off
    /// `.stew` for stew's own notice, such as the return summary or a new version: kept
    /// out of the history and off the phone.
    var source: ItemSource = .caller
    /// Option under the mouse, so its preview shows.
    @Published var hoveredOption: Int?
    /// For a needs item: its id in needs.json.
    var needsID: String?
    /// A request that timed out, shown again from the history: the answer goes to the
    /// session as a late answer instead of to a waiting caller.
    var lateEntryID: UUID?

    /// What the user typed into an input, starting with its default.
    @Published var inputText = ""
    /// The user started typing an answer, a note or a value for this request on the Mac.
    /// From then on its clock is stopped (only the caller's hard limit, `maxWait`, still
    /// applies) and it is never sent to a phone: someone is at the Mac, answering it.
    @Published var typedOnMac = false

    var isNeeds: Bool {
        if case .needs = request.prompt { return true }
        return false
    }

    var input: InputRequest? {
        if case .input(let input) = request.prompt { return input }
        return nil
    }

    init(request: StewRequest, connection: Connection?) {
        self.request = request
        self.connection = connection
        if case .question(let set) = request.prompt {
            flow = QuestionFlow(questions: set.questions)
        }
        if case .input(let input) = request.prompt {
            inputText = input.defaultText ?? ""
        }
    }

    var isHardDeny: Bool {
        if case .blocked(let blocked) = risk { return blocked.hardDeny }
        return risk.assessment?.verdict == .hardDeny
    }

    var blocked: BlockedCall? {
        if case .permission(let permission) = request.prompt { return permission.blocked }
        return nil
    }
}

/// What a hotkey or click does on the current panel.
enum PanelAction: Equatable {
    case action(HotkeyAction)
    case option(Int)
    /// In grant mode: keep the chosen scope for good instead of an hour.
    case grantAlways
}

/// History's preview of a finished request, drawn with the panel's views.
enum HistoryPreviewMode: Equatable {
    /// Timed out, or a secret set aside for later, and still answerable: the panel's
    /// buttons answer it late. No clock; the header says when it ended, such as
    /// "Timed out Nov 14 at 11:22".
    case late(ended: String)
    /// Ended for good: the panel's content without its buttons.
    case ended

    /// Closing, more time and "later" belong to a waiting caller; a preview has none.
    /// An ended request only pages through its questions.
    func allows(_ action: HotkeyAction) -> Bool {
        switch self {
        case .late: ![.dismiss, .dismissAll, .extend, .enterLater, .enterSoon].contains(action)
        case .ended: [.next, .previous].contains(action)
        }
    }
}

final class Coordinator: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var textMode = false
    /// The "Allow more…" view of a blocked call, with the scope picked in it.
    @Published private(set) var grantMode = false
    @Published private(set) var grantSelection = 0
    @Published var draft = "" {
        didSet {
            if !draft.isEmpty, draft != oldValue, let current { typed(current) }
        }
    }
    @Published private(set) var keymap: Keymap
    @Published private(set) var configError: String?
    @Published private(set) var hotkeyFailures: [Shortcut] = []
    private(set) var config: StewConfig
    /// Snapshots: the panel look to render, whatever the config file says.
    var lookOverride: String?
    var panelLook: String { lookOverride ?? config.panelLook }
    /// Told about every answer before its item leaves, so paired phones learn the outcome.
    var onRespond: ((Item, StewResponse) -> Void)?
    /// The paired phone answering this item right now, by name, so the history says
    /// where it was answered. Nil: the user answered on the Mac.
    var answeringPhone: ((Item) -> String?)?
    /// The Mac as the history names it when the user answered here.
    static let macName = Host.current().localizedName ?? "Mac"
    /// Set on History's preview of a request: what it may do, and where its answers go.
    var historyPreview: HistoryPreviewMode?
    /// True while History's preview has the keyboard: the panel's keys then answer the
    /// preview, so the floating panel lets go of them, and a key never answers a request
    /// the user is not looking at.
    var panelKeysSuspended = false {
        didSet { if panelKeysSuspended != oldValue { onChange?() } }
    }
    /// The previews that have the keyboard: History's and the menu bar popover's.
    private var previewKeyOwners: Set<String> = []

    /// A preview, named by `owner`, takes the panel's keys or lets go of them. The
    /// floating panel gets them back once no preview has them.
    func previewKeys(taken: Bool, by owner: String) {
        if taken { previewKeyOwners.insert(owner) } else { previewKeyOwners.remove(owner) }
        panelKeysSuspended = !previewKeyOwners.isEmpty
    }
    /// False in History's preview of an ended request: its buttons give way to the outcome.
    var showsButtons: Bool { historyPreview != .ended }
    /// History's preview: a late answer goes to the daemon's coordinator, which stores it
    /// and keeps a secret in memory. Returns false when it is too late.
    var onPreviewAnswer: ((UUID, StewResponse) -> Bool)?
    /// Gets controls this class does not know; a non-nil reply answers the caller.
    var onControl: ((String) -> String?)?
    /// Told when a needs item ends for good, with how it ended, so paired phones learn it.
    var onNeedsFinished: ((NeedsItem, HistoryEntry.Outcome) -> Void)?
    private var configModified: Date?
    var onChange: (() -> Void)?
    var onStop: (() -> Void)?
    var onOpenSettings: ((SettingsTab) -> Void)?
    /// Shows confetti where the panel is. Called just before an approved request leaves it.
    var onCelebrate: (() -> Void)?
    /// How many approvals asked for confetti, for the end-to-end tests.
    private(set) var celebrations = 0
    /// Called after every change while no request is open, so a waiting update can install.
    var onIdle: (() -> Void)?
    /// Where finished requests are recorded. Nil when rendering snapshots.
    var history: HistoryStore?
    /// Opens the menu bar popover on its requests; true shows only missed requests. The
    /// id selects that request.
    var onOpenHistory: ((Bool, UUID?) -> Void)?
    /// Called after a late answer is stored, so the History tab shows it.
    var onLateAnswer: (() -> Void)?
    /// `stew update`: check and install now, then reply with the outcome.
    var onUpdate: ((@escaping (UpdateOutcome) -> Void) -> Void)?
    /// Open needs items. In memory only until the daemon gives it needs.json.
    var needsStore = NeedsStore(path: nil)
    /// Called whenever what the menu bar shows may have changed.
    var onMenuBarChange: ((MenuBarState) -> Void)?
    /// The pause, when History was last opened, and the update notices. In memory only
    /// until the daemon gives it daemon-state.json.
    var stateStore = DaemonStateStore(path: nil)
    /// The pause, for the settings window.
    let pauseModel = PauseModel()
    /// The update entry of the menu, kept current by the daemon from the updater.
    var updateEntry: MenuBarState.Update? {
        didSet { if updateEntry != oldValue { menuBarChanged() } }
    }
    /// "Install now" on an update notice, and the update entry of the menu.
    var onInstallUpdate: (() -> Void)?
    /// Missed requests the user has not seen in History yet.
    private(set) var missedCount = 0
    private var pauseCheck: Timer?
    /// The pause as the menu bar and settings window last showed it.
    private var shownPause: PauseDisplay?
    /// When a pause last ended because the user came back, so the away watcher does not
    /// report the same return again.
    private var lastReturn: Date?
    /// The last simulated keyboard or mouse input and screen lock, in the headless test
    /// daemon.
    private var testLastInput: Date?
    private var testScreenLocked = false
    /// Callers of `stew needs --wait`, by item id. The item can leave the panel ("Not
    /// now") while its caller still waits.
    private var needsWaiters: [String: NeedsWaiter] = [:]

    private struct NeedsWaiter {
        let connection: Connection
        let timer: DispatchWorkItem?
    }

    var current: Item? { items.first }

    /// Nothing the user must answer now. Open needs items can wait days, so they never
    /// hold back an update; the restart keeps them in needs.json.
    var isIdle: Bool { items.allSatisfy(\.isNeeds) && !textMode }

    init(config: StewConfig = StewConfig()) {
        self.config = config
        keymap = (try? Keymap(config: config)) ?? (try! Keymap(config: StewConfig()))
        reloadConfigIfChanged()
    }

    /// Re-read on each new request, so edits to config.json apply without a restart.
    func reloadConfigIfChanged() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: Paths.config)
        let modified = attributes?[.modificationDate] as? Date
        guard modified != configModified else { return }
        configModified = modified
        let (loaded, error) = loadConfig()
        config = loaded
        configError = error
        keymap = (try? Keymap(config: loaded)) ?? (try! Keymap(config: StewConfig()))
    }

    func receive(line: Data, from connection: Connection) {
        if let control = try? Wire.decode(ControlMessage.self, line: line) {
            handle(control: control.control, connection: connection)
            return
        }
        do {
            let request = try Wire.decode(StewRequest.self, line: line)
            if case .question(let set) = request.prompt { try set.validate() }
            if case .needs(let needs) = request.prompt { try needs.validate() }
            if case .input(let input) = request.prompt { try input.validate() }
            enqueue(request, connection: connection)
        } catch {
            connection.send((try? Wire.encode(StewResponse(status: .error, error: "bad request: \(error)"))) ?? Data())
        }
    }

    private func handle(control: String, connection: Connection) {
        switch control {
        case "stop":
            connection.send(Data("stopping\n".utf8))
            dismissAllForShutdown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.onStop?() }
        case "status":
            connection.send(Data("\(items.count) pending\n".utf8))
        case "approvals", "settings":
            connection.send(Data("opened\n".utf8))
            onOpenSettings?(control == "approvals" ? .approvals : .general)
        case "history", "history missed":
            connection.send(Data("opened\n".utf8))
            openHistory(missedOnly: control == "history missed")
        case "resume":
            let starting = chosenPause?.isPending(now: Date()) ?? false
            let reply = resume() ? (starting ? "pause canceled" : "stew resumed") : "stew is not paused"
            connection.send(Data((reply + "\n").utf8))
        case _ where control.hasPrefix("pause "):
            guard let choice = PauseChoice(controlArgument: String(control.dropFirst("pause ".count))) else {
                connection.send(Data("error: pause takes a whole number of minutes from 1 to \(PauseState.maximumMinutes), until HH:MM, or back\n".utf8))
                return
            }
            pause(choice)
            connection.send(Data((pauseDescription + "\n").utf8))
        case "update":
            guard let onUpdate else {
                connection.send((try? Wire.encode(UpdateOutcome(status: .checkFailed, message: "this daemon cannot update"))) ?? Data())
                return
            }
            onUpdate { outcome in connection.send((try? Wire.encode(outcome)) ?? Data()) }
        case _ where control.hasPrefix("needs "):
            connection.send(handleNeeds(control: String(control.dropFirst("needs ".count))))
        case _ where control.hasPrefix("late secret "):
            connection.send(handOverSecret(entryID: String(control.dropFirst("late secret ".count))))
        default:
            if let reply = onControl?(control) {
                connection.send(Data((reply + "\n").utf8))
                return
            }
            if Paths.headless, let reply = handleTestControl(control) {
                connection.send(Data((reply + "\n").utf8))
                return
            }
            connection.send(Data("unknown control \(control)\n".utf8))
        }
    }

    func enqueue(_ request: StewRequest, connection: Connection?, lateEntryID: UUID? = nil) {
        reloadConfigIfChanged()
        // A late answer is the user's own doing, so it shows also while paused.
        if let pause = activePause, PauseState.timesOut(request.prompt), lateEntryID == nil {
            timeOutWhilePaused(request, connection: connection, pause: pause)
            return
        }
        if case .needs(let needs) = request.prompt {
            addNeeds(needs, request: request, connection: connection)
            return
        }
        let item = Item(request: request, connection: connection)
        item.lateEntryID = lateEntryID
        if case .notify = request.prompt, !request.wait {
            // The caller only wants it shown; the panel keeps it until dismissed.
            connection?.send((try? Wire.encode(StewResponse(status: .shown))) ?? Data())
            item.connection = nil
        }
        item.timeLimit = request.timeLimit(defaultTimeout: config.responseTimeout)
        if case .permission(let permission) = request.prompt, let blocked = permission.blocked {
            item.risk = .blocked(blocked)
        } else if case .permission(let permission) = request.prompt, config.classifier.enabled {
            item.risk = .checking
            RiskChecker(config: config.classifier).check(permission, session: request.session) { [weak self, weak item] result in
                guard let item else { return }
                switch result {
                case .success(let assessment):
                    item.risk = .done(assessment)
                    self?.addSeverityTime(item, assessment)
                case .failure(let error): item.risk = .failed("\(error)")
                }
                self?.changed()
            }
        }
        let wasEmpty = items.isEmpty
        items.append(item)
        arrangeQueue()
        if wasEmpty {
            ArrivalSound.play(config.sound)
        }
        changed()
    }

    /// Needs items wait behind everything else; see `PanelQueue`.
    private func arrangeQueue() {
        items = PanelQueue.ordered(items, frontPinned: textMode, isNeeds: \.isNeeds)
    }

    /// Commands for needs items: "resolve ID" (Claude saw it done) and "answered
    /// SESSION" (the user wrote to that session, from the prompt hook).
    private func handleNeeds(control: String) -> Data {
        let parts = control.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let response: StewResponse
        switch parts.first {
        case "resolve":
            if finishNeeds(id: argument, outcome: .resolvedByClaude, status: .resolved, note: nil) {
                response = StewResponse(status: .resolved, id: argument)
            } else {
                response = StewResponse(status: .error, id: argument, error: "no open needs item with id \(argument)")
            }
        case "answered", "moved-on":
            // "moved-on": a later turn of the session ended without a `needs input:` line,
            // so it no longer waits on what the automatic item asked for.
            let outcome: HistoryEntry.Outcome = parts.first == "answered" ? .answeredInSession : .movedOn
            let answered = NeedsBook.answeredBy(sessionID: argument, in: needsStore.items)
            for record in answered {
                finishNeeds(id: record.id, outcome: outcome, status: .resolved, note: nil)
            }
            response = StewResponse(status: .resolved, note: "\(answered.count) resolved")
        default:
            response = StewResponse(status: .error, error: "unknown needs command \(control)")
        }
        return (try? Wire.encode(response)) ?? Data()
    }

    /// A new needs item: kept in needs.json, shown when nothing else is waiting. Without
    /// --wait the caller gets its id at once; with it, the caller waits for Done or
    /// Decline, or until its own --timeout.
    private func addNeeds(_ needs: NeedsRequest, request: StewRequest, connection: Connection?) {
        if needs.automatic, NeedsBook.hasOpenCLIItem(sessionID: request.session.id, in: needsStore.items) {
            let response = StewResponse(status: .dismissed, note: "The session already has an open item from stew needs")
            connection?.send((try? Wire.encode(response)) ?? Data())
            return
        }
        let record = NeedsItem(id: NeedsBook.newID(existing: needsStore.items), created: Date(), session: request.session, needs: needs)
        for replaced in needsStore.add(record) {
            // A session's newer automatic need supersedes its older one; the old one
            // never ended, so it goes without a history entry.
            if let panelItem = items.first(where: { $0.needsID == replaced.id }) { remove(panelItem) }
            answerWaiter(replaced.id, StewResponse(status: .resolved, note: "Replaced by a newer need from this session", id: replaced.id))
        }
        if request.wait, let connection {
            var timer: DispatchWorkItem?
            if let limit = request.timeout, limit > 0 {
                let id = record.id
                let work = DispatchWorkItem { [weak self] in
                    let minutes = max(1, Int((limit / 60).rounded()))
                    let span = limit < 60 ? "\(Int(limit)) s" : "\(minutes) min"
                    let note = "The user has not done this within \(span). It stays open in stew: continue with work that does not need it, and run `stew needs resolve \(id)` once you can see it is done."
                    self?.answerWaiter(id, StewResponse(status: .timeout, note: note, id: id))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
                timer = work
            }
            needsWaiters[record.id] = NeedsWaiter(connection: connection, timer: timer)
        } else {
            connection?.send((try? Wire.encode(StewResponse(status: .shown, id: record.id))) ?? Data())
        }
        queueNeeds(record)
        needsChanged()
    }

    /// Puts an open needs item in the panel queue, behind everything else. While stew is
    /// paused it waits in the menu bar, unless the user opens it there (`evenWhilePaused`).
    private func queueNeeds(_ record: NeedsItem, evenWhilePaused: Bool = false) {
        guard !items.contains(where: { $0.needsID == record.id }) else { return }
        guard evenWhilePaused || activePause == nil else { return }
        let item = Item(request: StewRequest(session: record.session, prompt: .needs(record.needs), wait: false), connection: nil)
        item.needsID = record.id
        let wasEmpty = items.isEmpty
        items.append(item)
        arrangeQueue()
        if wasEmpty { ArrivalSound.play(config.sound) }
        changed()
    }

    /// The daemon started: open items come back, except the ones parked with "Not now",
    /// which wait in the menu bar.
    func restoreNeeds() {
        for record in needsStore.items where !record.parked {
            queueNeeds(record)
        }
        needsChanged()
    }

    /// The menu bar: show this item, also when it is parked. It goes to the front of the
    /// needs items, still behind requests that need an answer now.
    func openNeeds(id: String) {
        guard let record = needsStore.item(id) else { return }
        if record.parked {
            needsStore.update(id) { $0.parked = false }
        }
        if let existing = items.first(where: { $0.needsID == id }), current?.id != existing.id {
            items.removeAll { $0.id == existing.id }
            let firstNeeds = items.firstIndex(where: \.isNeeds) ?? items.count
            items.insert(existing, at: textMode ? max(firstNeeds, 1) : firstNeeds)
            changed()
        } else {
            queueNeeds(record, evenWhilePaused: true)
        }
        needsChanged()
    }

    /// Ends a needs item for good: history entry, answer for a waiting caller, gone from
    /// the panel and needs.json. `answer` is the label of the answer the user picked.
    @discardableResult
    private func finishNeeds(
        id: String, outcome: HistoryEntry.Outcome, status: StewStatus, note: String?, answer: String? = nil, answeredOn device: String? = nil
    ) -> Bool {
        guard let record = needsStore.remove(id) else { return false }
        // Claude resolving it, or the session moving on, is no answer from a device.
        let byUser = [.done, .answered, .dismissed].contains(outcome)
        let entry = HistoryEntry.record(
            record, outcome: outcome, note: note, answer: answer, ended: Date(), answeredOn: byUser ? device ?? Self.macName : nil
        )
        history?.append(entry)
        onNeedsFinished?(record, outcome)
        answerWaiter(id, StewResponse(status: status, note: note, id: id, answer: answer))
        if let panelItem = items.first(where: { $0.needsID == id }) {
            remove(panelItem)
        } else {
            changed()
        }
        needsChanged()
        return true
    }

    /// Done (`answerIndex` nil) or one of the item's other answers, from the panel or a
    /// paired phone. False when the item is gone or has no answer at `answerIndex`.
    @discardableResult
    func answerNeeds(id: String, answerIndex: Int?, note: String?, answeredOn device: String? = nil) -> Bool {
        guard let record = needsStore.item(id) else { return false }
        let label = record.needs.answerLabel(at: answerIndex)
        guard let answerIndex else {
            return finishNeeds(id: id, outcome: .done, status: .done, note: note, answer: label, answeredOn: device)
        }
        guard label != nil, record.needs.answers.indices.contains(answerIndex) else { return false }
        return finishNeeds(id: id, outcome: .answered, status: .answered, note: note, answer: label, answeredOn: device)
    }

    /// "Not now": out of the panel, still open in the menu bar. A waiting caller keeps waiting.
    private func park(_ item: Item) {
        guard let id = item.needsID else { return }
        needsStore.update(id) { $0.parked = true }
        remove(item)
        needsChanged()
    }

    private func answerWaiter(_ id: String, _ response: StewResponse) {
        guard let waiter = needsWaiters.removeValue(forKey: id) else { return }
        waiter.timer?.cancel()
        waiter.connection.send((try? Wire.encode(response)) ?? Data())
    }

    private func needsChanged() {
        menuBarChanged()
    }

    /// Simulated input for end-to-end tests: "press approve", "choose 2", "type text", "state".
    private func handleTestControl(_ control: String) -> String? {
        let parts = control.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "press":
            if argument == "always" {
                grantAlways()
            } else {
                guard let action = HotkeyAction(rawValue: argument) else { return "unknown action" }
                perform(action)
            }
        case "choose":
            guard let number = Int(argument) else { return "bad option" }
            choose(option: number - 1)
        case "type":
            if let item = current, item.input != nil {
                item.inputText = argument
                typed(item)
                changed()
            } else {
                draft = argument
            }
        case "returned":
            // Simulates the user coming back after `argument` seconds away.
            idleUserReturned(awaySince: Date().addingTimeInterval(-(Double(argument) ?? 0)))
        case "announce":
            // The update check found `argument`, which a test daemon never checks for.
            announceAvailable(argument, route: .inPlace)
        case "open":
            // A click on a needs item in the menu bar.
            openNeeds(id: argument)
        case "late":
            // A missed request shown in the panel again, to answer it late there.
            guard let entryID = UUID(uuidString: argument), answerLate(entryID: entryID) else { return "not waiting" }
        case "menu":
            // What the menu bar item shows, which a headless daemon does not create.
            reloadConfigIfChanged()
            return menuBarState.describe(timeText: Self.clockText)
        case "title":
            // The notification on screen: its title, and its link when it has one.
            guard case .notify(let notify) = current?.request.prompt else { return "-" }
            return [notify.title, notify.link.map { "\($0.title) \($0.url)" }].compactMap { $0 }.joined(separator: " | ")
        case "pausefor":
            // A pause of a few seconds, to see it end by itself.
            guard let seconds = Double(argument), seconds > 0 else { return "bad seconds" }
            pause(seconds: seconds)
        case "input":
            // Keyboard or mouse input from the user, which a test daemon never has.
            testLastInput = Date()
            checkPause()
        case "screen":
            // "screen locked" or "screen unlocked", as the system announces it.
            guard ["locked", "unlocked"].contains(argument) else { return "bad screen state" }
            testScreenLocked = argument == "locked"
            screenLockChanged(locked: testScreenLocked)
        case "state":
            break
        default:
            return nil
        }
        let risk: String
        switch current?.risk {
        case .checking: risk = "checking"
        case .done(let assessment): risk = assessment.verdict.rawValue
        case .failed(let reason): risk = "failed: \(reason)"
        case .blocked(let blocked): risk = "blocked:\(blocked.hardDeny ? "hard" : "soft")"
        case .off, nil: risk = "off"
        }
        let severity = current?.risk.assessment?.severity?.rawValue ?? "-"
        let viewingState = current.flatMap { item in isViewing(item) ? item.viewing?.phoneName : nil } ?? "-"
        let bindings = activeBindings().map { "\($0.0)" }.joined(separator: " ")
        var clockState = "none"
        if let deadline = current?.deadline { clockState = "running:\(Int(deadline.timeIntervalSinceNow.rounded()))" }
        if let remaining = current?.pausedRemaining { clockState = "paused:\(Int(remaining.rounded()))" }
        let needsState = "needs=\(needsStore.items.count) parked=\(needsStore.items.filter(\.parked).count) front=\(current?.needsID ?? "-")"
        var inputState = "-"
        if let item = current, let input = item.input {
            switch input.check(item.inputText) {
            case .empty: inputState = "empty"
            case .mismatch: inputState = "mismatch"
            case .valid: inputState = "valid"
            }
        }
        return "items=\(items.count) kind=\(current?.request.prompt.kind ?? "none") question=\(current?.flow?.index ?? -1) text=\(textMode) input=\(inputState) grant=\(grantMode):\(grantSelection) clock=\(clockState) risk=\(risk) severity=\(severity) viewing=\(viewingState) confetti=\(celebrations) \(needsState) keys=\(bindings) notice=\(current?.questionNotice ?? "-")"
    }

    /// Puts a prepared item on screen without a caller or risk check (snapshots).
    func show(_ item: Item) {
        item.timeLimit = item.timeLimit ?? item.request.timeLimit(defaultTimeout: config.responseTimeout)
        items.append(item)
        changed()
    }

    /// History's preview: the one item, with no clock.
    func showPreview(_ item: Item, mode: HistoryPreviewMode) {
        historyPreview = mode
        item.timeLimit = nil
        items = [item]
        changed()
    }

    func connectionClosed(_ connectionID: UUID) {
        if let (id, waiter) = needsWaiters.first(where: { $0.value.connection.id == connectionID }) {
            // The caller stopped waiting; the item itself stays open.
            waiter.timer?.cancel()
            needsWaiters[id] = nil
            return
        }
        guard let item = items.first(where: { $0.connection?.id == connectionID }) else { return }
        item.connection = nil
        record(item, nil)
        remove(item)
    }

    func respond(_ item: Item, _ answer: StewResponse) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        var response = answer
        // An input's answer names it by the id of its history entry, so a "later" status
        // and the late answer that follows belong together.
        if item.input != nil { response.id = item.id.uuidString.lowercased() }
        if config.celebrates(response, to: item.request.prompt) {
            // Before the item goes, so the panel is still where the user looked.
            celebrations += 1
            onCelebrate?()
        }
        if let entryID = item.lateEntryID, let onPreviewAnswer {
            if !onPreviewAnswer(entryID, response) { Log.write("late answer: \(entryID) is no longer waiting") }
        } else if let entryID = item.lateEntryID {
            storeLateAnswer(item.request, response, entryID: entryID)
        } else {
            record(item, response)
        }
        item.connection?.send((try? Wire.encode(response)) ?? Data())
        item.connection = nil
        onRespond?(item, response)
        remove(item)
    }

    private func remove(_ item: Item) {
        item.timer?.cancel()
        let wasCurrent = current?.id == item.id
        items.removeAll { $0.id == item.id }
        if wasCurrent {
            textMode = false
            grantMode = false
            grantSelection = 0
            draft = ""
        }
        changed()
    }

    func dismissAllForShutdown() {
        // Needs items stay open in needs.json and come back with the next daemon.
        for (id, waiter) in needsWaiters {
            waiter.timer?.cancel()
            let response = StewResponse(status: .error, id: id, error: "stew stopped before the user answered; the item stays open and shows again when stew starts")
            waiter.connection.send((try? Wire.encode(response)) ?? Data())
        }
        needsWaiters = [:]
        // A late answer in progress has no caller; its request stays answerable.
        for item in items where !item.isNeeds && item.lateEntryID == nil {
            let response = StewResponse(status: .dismissed, note: "stew daemon stopped")
            record(item, response, byUser: false)
            item.connection?.send((try? Wire.encode(response)) ?? Data())
        }
        items = []
        history?.flush()
    }

    /// No response means the caller went away before an answer. A request of a known
    /// session that timed out stays answerable from the history for a day.
    private func record(_ item: Item, _ response: StewResponse?, byUser: Bool = true) {
        // Needs items record their own ending in finishNeeds.
        guard let history, item.source == .caller, !item.isNeeds else { return }
        let device = byUser ? answeringPhone?(item) ?? Self.macName : nil
        let entry = HistoryEntry.record(
            item.request, received: item.received, response: response, ended: Date(), id: item.id, answeredOn: device
        )
        history.append(entry)
        let answerableLater = (response?.status == .timeout && LateMailbox.canAnswerLate(item.request))
            || (response?.status == .later && item.request.offersEnterLater)
        if answerableLater {
            LateAnswerFile.update { $0.addWaiting(item.request, entryID: entry.id, now: entry.ended) }
        }
        if entry.answerableLater { refreshMissed() }
    }

    /// Secrets entered late, by history entry, until a hook fetches them. Memory only:
    /// a secret is never written to a file, so a restart before delivery loses it.
    private var heldSecrets: [UUID: String] = [:]

    /// "late secret ID" from a hook: the secret of a late answer the hook has just
    /// marked delivered, once. Afterwards the daemon no longer has it.
    private func handOverSecret(entryID text: String) -> Data {
        let response: StewResponse
        if let entryID = UUID(uuidString: text.trimmingCharacters(in: .whitespaces)),
           LateAnswerFile.read().answer(entryID)?.delivered != nil,
           let secret = heldSecrets.removeValue(forKey: entryID) {
            response = StewResponse(status: .answered, text: secret)
        } else {
            response = StewResponse(status: .error, error: "no secret held for \(text)")
        }
        return (try? Wire.encode(response)) ?? Data()
    }

    /// Shows a timed-out request in the panel again, without a time limit, to answer it
    /// late there. False when it can no longer be answered (answered already, or more
    /// than a day old). Shown once: a second call brings the same item forward.
    @discardableResult
    func answerLate(entryID: UUID) -> Bool {
        if items.contains(where: { $0.lateEntryID == entryID }) { return true }
        guard let waiting = LateAnswerFile.read().waiting(entryID, now: Date()) else { return false }
        var request = waiting.request
        request.timeout = 0
        request.maxWait = nil
        enqueue(request, connection: nil, lateEntryID: entryID)
        return true
    }

    /// The request of a timed-out history entry that can still be answered late.
    func lateRequest(entryID: UUID) -> StewRequest? {
        LateAnswerFile.read().waiting(entryID, now: Date())?.request
    }

    /// A late answer given somewhere else than the panel, such as in History's preview or
    /// on the iPhone: stored exactly like a late answer in the panel. When the panel has
    /// the request, it closes with it. False when it can no longer be answered.
    func answerLate(entryID: UUID, with response: StewResponse, answeredOn device: String) -> Bool {
        if let item = items.first(where: { $0.lateEntryID == entryID }) {
            lateDevice = device
            defer { lateDevice = nil }
            respond(item, response)
            return LateAnswerFile.read().answer(entryID) != nil
        }
        guard let waiting = LateAnswerFile.read().waiting(entryID, now: Date()) else { return false }
        return storeLateAnswer(waiting.request, response, entryID: entryID, answeredOn: device)
    }

    /// Where the late answer being stored was given, when not in the panel.
    private var lateDevice: String?

    /// The user answered a timed-out request: store the answer for the session's next
    /// hook call, the one-shot retry grant for an approved blocked call, and the late
    /// outcome on the history entry. Closing the panel is no answer: the request stays
    /// answerable. False when nothing was stored.
    @discardableResult
    private func storeLateAnswer(_ request: StewRequest, _ response: StewResponse, entryID: UUID, answeredOn device: String? = nil) -> Bool {
        guard [.approved, .denied, .answered].contains(response.status) else { return false }
        let now = Date()
        // A secret stays out of late-answers.json and the history: the file gets a
        // placeholder, and the daemon keeps the secret until a hook fetches it.
        var isSecret = false
        if case .input(let input) = request.prompt { isSecret = input.secret }
        let secret = isSecret ? response.text : nil
        var stored = response
        if secret != nil { stored.text = nil }
        guard let late = LateAnswerFile.update(now: now, { $0.answer(entryID, with: stored, now: now) }) else {
            Log.write("late answer: \(entryID) is no longer waiting")
            return false
        }
        if let secret { heldSecrets[entryID] = secret }
        var blockedCall: BlockedCall?
        if case .permission(let permission) = request.prompt { blockedCall = permission.blocked }
        if response.status == .approved, let blocked = blockedCall, let origin = request.origin,
           let toolName = origin.toolName, let callKey = origin.callKey {
            do {
                try GrantFile.update { grants in
                    GrantBook.approveLate(grants: &grants, toolName: toolName, callKey: callKey, sessionID: late.sessionID, now: now)
                    if let choice = response.grant {
                        try Hooks.apply(choice, toolName: toolName, projectRoot: blocked.projectRoot, grants: &grants)
                    }
                }
            } catch {
                Log.write("late answer: could not store the grant: \(error)")
            }
        }
        let answeredOn = device ?? lateDevice ?? Self.macName
        history?.update(entryID) { $0.recordLate(stored, message: late.message, at: now, on: answeredOn) }
        onLateAnswer?()
        refreshMissed()
        return true
    }

    /// The away watcher saw the user come back after two idle minutes. A return that
    /// already ended a pause until they are back was summed up then.
    func idleUserReturned(awaySince: Date) {
        if let lastReturn, lastReturn >= awaySince { return }
        userReturned(awaySince: awaySince)
    }

    /// The user is back after being away since `awaySince`. One notice for every
    /// request that timed out meanwhile and every open needs item; nothing when there is
    /// neither. Parked needs items come back into the panel, each one only once.
    func userReturned(awaySince: Date) {
        // While paused the user is away by their own say; Resume shows the summary.
        guard let history, activePause == nil else { return }
        let entries = history.read()
        let missed = History.missed(entries, since: awaySince)
        let later = History.enterLater(entries, since: awaySince)
        for record in needsStore.items where record.parked && !record.reminded {
            needsStore.update(record.id) { item in
                item.parked = false
                item.reminded = true
            }
            queueNeeds(record)
            needsChanged()
        }
        guard let notice = ReturnSummary.notice(missedCount: missed.count, laterCount: later.count, needsCount: needsStore.items.count) else { return }
        showNotice(notice)
    }

    /// stew's own notice, such as the return summary or a new version: shown like a
    /// notification, kept out of the history and never sent to a phone.
    func showNotice(_ notice: NotifyRequest) {
        let item = Item(request: StewRequest(session: SessionInfo(name: "stew"), prompt: .notify(notice), wait: false), connection: nil)
        item.source = .stew
        items.append(item)
        arrangeQueue()
        changed()
    }

    /// A version found and not installed: one notice per version.
    func announceAvailable(_ version: String, route: UpdateRoute) {
        guard let notice = UpdateNotice.available(version, route: route, state: stateStore.state) else { return }
        stateStore.update { state in
            state.announcedVersions = Array((state.announcedVersions + [version]).suffix(20))
        }
        showNotice(notice)
    }

    /// The daemon started: the pause comes back unless it ran out meanwhile, missed
    /// requests are counted, and a first start counts everything before it as seen.
    func restoreState() {
        if stateStore.state.historySeenAt == nil {
            stateStore.update { $0.historySeenAt = Date() }
        }
        if stateStore.state.pause != nil, chosenPause == nil {
            stateStore.update { $0.pause = nil }
        }
        schedulePauseCheck()
        pauseChanged()
        refreshMissed()
    }

    /// The pause in effect now, if any.
    var activePause: PauseState? {
        guard let pause = chosenPause, pause.isActive(now: Date()) else { return nil }
        return pause
    }

    /// The pause in effect, or Until I'm back in the minute before it begins.
    var chosenPause: PauseState? {
        guard let pause = stateStore.state.pause, !pause.hasEnded(now: Date()) else { return nil }
        return pause
    }

    /// Pauses stew as `choice` says. Pausing again replaces how it ends, and keeps when
    /// the pause began for the summary on Resume.
    func pause(_ choice: PauseChoice) {
        let pause = choice.pause(
            now: Date(), calendar: .current, current: chosenPause, screenLocked: samplePresence().screenLocked, armingDelay: Self.pauseArmingDelay
        )
        stateStore.update { $0.pause = pause }
        if let until = pause.until {
            Log.write("paused until \(Self.clockText(until))")
        } else {
            Log.write("paused until the user is back, from \(Self.clockText(pause.since))")
        }
        schedulePauseCheck()
        pauseChanged()
    }

    /// Pauses stew for `seconds` from now, for the end-to-end tests of a pause that ends
    /// by itself.
    func pause(seconds: Double) {
        let now = Date()
        stateStore.update { $0.pause = PauseState(since: activePause?.since ?? now, until: now.addingTimeInterval(seconds)) }
        Log.write("paused until \(Self.clockText(now.addingTimeInterval(seconds)))")
        schedulePauseCheck()
        pauseChanged()
    }

    /// Ends the pause by the user's hand, or because they came back: needs items that
    /// waited come into the panel, with the summary of what timed out meanwhile. In the
    /// minute before Until I'm back begins, it only cancels it. False when stew was not
    /// paused.
    @discardableResult
    func resume() -> Bool {
        guard let pause = chosenPause else { return false }
        guard pause.isActive(now: Date()) else {
            pauseCheck?.invalidate()
            pauseCheck = nil
            stateStore.update { $0.pause = nil }
            Log.write("pause canceled")
            pauseChanged()
            return true
        }
        endPause()
        userReturned(awaySince: History.wholeSecond(pause.since))
        return true
    }

    /// Needs items that waited during the pause come into the panel. When the pause runs
    /// out by itself the user may still be away, so the summary waits for their return.
    private func endPause() {
        pauseCheck?.invalidate()
        pauseCheck = nil
        stateStore.update { $0.pause = nil }
        Log.write("pause ended")
        for record in needsStore.items where !record.parked {
            queueNeeds(record)
        }
        pauseChanged()
    }

    /// Checks the wall clock at the end of the pause, and at least every 30 seconds, so
    /// a Mac that slept through the end still resumes on time. An armed pause until the
    /// user is back samples the idle time every few seconds instead.
    private func schedulePauseCheck() {
        pauseCheck?.invalidate()
        pauseCheck = nil
        guard let pause = chosenPause else { return }
        let now = Date()
        let wait: TimeInterval
        switch pause.ending {
        case .afterMinutes, .atTime:
            wait = min(max(0, (pause.until ?? now).timeIntervalSince(now)), 30)
        case .whenBack:
            if let armsAt = pause.armsAt, armsAt > now {
                wait = min(armsAt.timeIntervalSince(now), 30)
            } else {
                wait = Self.returnSampleInterval
            }
        }
        pauseCheck = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            self?.checkPause()
        }
    }

    /// Ends a pause that ran out, resumes one until the user is back once they are, and
    /// shows a pause that began.
    private func checkPause() {
        guard let pause = stateStore.state.pause else { return }
        let now = Date()
        if pause.hasEnded(now: now) {
            endPause()
            return
        }
        let presence = samplePresence()
        if pause.userIsBack(now: now, idleSeconds: presence.idleSeconds, screenLocked: presence.screenLocked) {
            Log.write("the user is back: resuming")
            resume()
            lastReturn = Date()
            return
        }
        if pause.display(now: now) != shownPause { pauseChanged() }
        schedulePauseCheck()
    }

    /// The screen locked or unlocked. Locking says the user is leaving, so Until I'm
    /// back begins at once; unlocking after that says they are back.
    func screenLockChanged(locked: Bool) {
        guard let pause = chosenPause else { return }
        let now = Date()
        if locked {
            let begun = pause.lockingScreen(at: now)
            guard begun != pause else { return }
            stateStore.update { $0.pause = begun }
            Log.write("screen locked: the pause until the user is back begins now")
            schedulePauseCheck()
            pauseChanged()
        } else if pause.endsOnUnlock(at: now) {
            Log.write("screen unlocked: resuming")
            resume()
            lastReturn = Date()
        }
    }

    /// Idle time and screen lock. The headless test daemon has no user, so the `input`
    /// and `screen` test controls stand in for one.
    private func samplePresence() -> MacPresence {
        guard Paths.headless else { return MacPresence.sampled() }
        return MacPresence(idleSeconds: testLastInput.map { Date().timeIntervalSince($0) } ?? .infinity, screenLocked: testScreenLocked)
    }

    /// How often an armed pause until the user is back looks for input.
    private static let returnSampleInterval: TimeInterval = 2

    /// The headless test daemon can shorten the minute before Until I'm back begins
    /// with STEW_PAUSE_ARMING.
    static var pauseArmingDelay: TimeInterval {
        guard Paths.headless, let text = ProcessInfo.processInfo.environment["STEW_PAUSE_ARMING"], let seconds = Double(text) else {
            return PauseState.armingDelay
        }
        return seconds
    }

    private func pauseChanged() {
        shownPause = chosenPause?.display(now: Date())
        pauseModel.display = shownPause
        menuBarChanged()
    }

    /// The reply to `stew pause`.
    var pauseDescription: String {
        let effect = "Permission requests, questions and inputs time out at once; notifications and needs items still arrive."
        let now = Date()
        switch chosenPause?.display(now: now) {
        case nil:
            return "stew is not paused"
        case .until(let date):
            return "stew is paused until \(Self.clockText(date)). \(effect)"
        case .untilBack:
            return "stew is paused until there is keyboard or mouse input again, or the screen is unlocked. \(effect)"
        case .startsAt(let date):
            return "stew pauses in \(PauseDisplay.countdown(to: date, now: now)), then stays paused until there is keyboard or mouse input again, or the screen is unlocked. \(effect)"
        }
    }

    /// The end of a pause: the time today, "08:00 tomorrow", else the date and time.
    static func clockText(_ date: Date) -> String {
        PauseState.endText(
            date, now: Date(), calendar: .current,
            time: { time in PauseState.timeOfDay(time) },
            dateAndTime: HistoryEntry.timeText
        )
    }

    /// A request that needs an answer now, while paused: it times out at once and Claude
    /// is told the user is away. It goes to the history like any timeout, so the user
    /// can still answer it late.
    private func timeOutWhilePaused(_ request: StewRequest, connection: Connection?, pause: PauseState) {
        let item = Item(request: request, connection: connection)
        let resumes = pause.resumesText(now: Date(), timeText: Self.clockText)
        let response = StewResponse(status: .timeout, note: request.pausedNote(resumes: resumes))
        record(item, response)
        connection?.send((try? Wire.encode(response)) ?? Data())
        Log.write("paused: a \(request.prompt.kind) from \(request.session.name) timed out at once")
    }

    var menuBarState: MenuBarState {
        MenuBarState(
            openNeeds: needsStore.items,
            missedCount: missedCount,
            pause: chosenPause?.display(now: Date()),
            update: updateEntry,
            showsAlways: config.menuBar,
            morningHour: config.pauseMorningHour,
            monochromeIcon: config.menuBarIcon == MenuBarIconStyle.monochrome
        )
    }

    func menuBarChanged() {
        onMenuBarChange?(menuBarState)
    }

    /// Recounts the missed requests the user has not seen yet.
    func refreshMissed() {
        guard let history else { return }
        let count = MenuBarBadge.unseenMissed(history.read(), seenAt: stateStore.state.historySeenAt)
        guard count != missedCount else { return }
        missedCount = count
        menuBarChanged()
    }

    /// Opens the history in the menu bar popover, which counts as seeing the missed
    /// requests in it.
    func openHistory(missedOnly: Bool, select entryID: UUID? = nil) {
        onOpenHistory?(missedOnly, entryID)
        historySeen()
    }

    /// The user cleared the history: every entry goes, and with it the requests that
    /// could still be answered late. Answers given but not yet delivered still reach Claude.
    func clearHistory() {
        history?.clear()
        LateAnswerFile.update { $0.forgetHistory() }
        Log.write("history: cleared by the user")
        refreshMissed()
    }

    /// The history showed, in the popover or the History pane: missed requests so far
    /// count as seen. Returns when it showed before.
    @discardableResult
    func historySeen() -> Date? {
        let previous = stateStore.state.historySeenAt
        stateStore.update { $0.historySeenAt = Date() }
        refreshMissed()
        return previous
    }

    private func changed() {
        syncTimer()
        onChange?()
        if isIdle { onIdle?() }
    }

    /// The user typed into the request on screen: its clock stops and it stays off the
    /// phone. Called on the first change and every one after it; only the first acts.
    func typed(_ item: Item) {
        guard !item.typedOnMac, !item.isNeeds, item === current else { return }
        item.typedOnMac = true
        Log.write("request \(item.id.uuidString.prefix(8)): typed on the Mac, clock stopped")
        changed()
    }

    /// The clock runs only for the request on screen, and pauses while the user types
    /// a note or picks a grant, so taking care over an answer never times it out. Once
    /// the user has typed into it, it stops for good, up to the caller's hard limit.
    private func syncTimer() {
        guard let item = current, let limit = item.timeLimit else { return }
        if item.typedOnMac {
            item.pausedRemaining = nil
            item.deadline = item.latestDeadline
        } else {
            if item.deadline == nil && item.pausedRemaining == nil {
                item.grantedSeconds = limit
                item.deadline = item.capped(Date().addingTimeInterval(limit))
            }
            let shouldPause = textMode || grantMode || isViewing(item)
            if shouldPause, let deadline = item.deadline {
                item.pausedRemaining = max(0, deadline.timeIntervalSinceNow)
                item.deadline = nil
            } else if !shouldPause, let remaining = item.pausedRemaining {
                item.pausedRemaining = nil
                item.deadline = item.capped(Date().addingTimeInterval(remaining))
            }
        }
        item.timer?.cancel()
        item.timer = nil
        guard let deadline = item.deadline else { return }
        let timer = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item else { return }
            self.expire(item)
        }
        item.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: timer)
    }

    /// Times the request out now. Also used when a phone answer arrives the moment the
    /// time ran out, before the timer fired, so it can go as a late answer.
    func expire(_ item: Item, reason: String? = nil) {
        let note = [item.request.timeoutNote(after: item.grantedSeconds), reason].compactMap { $0 }.joined(separator: " ")
        respond(item, StewResponse(status: .timeout, note: note, risk: item.risk.assessment))
    }

    /// True while a phone has the request open and the pause has not run out.
    func isViewing(_ item: Item) -> Bool {
        item.viewing?.isActive(at: Date(), cap: config.phone.viewingCap, grace: Self.viewingGrace) == true
    }

    /// The headless test daemon can shorten the grace period with STEW_VIEWING_GRACE.
    static let viewingGrace: TimeInterval = {
        guard Paths.headless, let text = ProcessInfo.processInfo.environment["STEW_VIEWING_GRACE"], let seconds = Double(text) else { return ViewingPause.grace }
        return seconds
    }()

    /// A paired phone opened the request: its clock pauses, the same as while typing a
    /// note, until the phone leaves it or the cap runs out. False when it does not pause,
    /// such as past the cap.
    @discardableResult
    func startViewing(_ item: Item, phoneName: String, pairingId: String) -> Bool {
        let now = Date()
        if var pause = item.viewing {
            pause.viewed(at: now, phoneName: phoneName, pairingId: pairingId, cap: config.phone.viewingCap)
            item.viewing = pause
        } else {
            item.viewing = ViewingPause(phoneName: phoneName, pairingId: pairingId, started: now)
        }
        scheduleViewingEnd(item)
        changed()
        return isViewing(item)
    }

    /// The phone left the request: the clock runs again after the grace period.
    func stopViewing(_ item: Item, pairingId: String) {
        guard var pause = item.viewing else { return }
        pause.left(at: Date(), pairingId: pairingId)
        item.viewing = pause
        scheduleViewingEnd(item)
        changed()
    }

    private func scheduleViewingEnd(_ item: Item) {
        item.viewingTimer?.cancel()
        guard let pause = item.viewing else { return }
        let cap = config.phone.viewingCap
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item, let pause = item.viewing, self.items.contains(where: { $0 === item }) else { return }
            if pause.reachedCap(at: Date(), cap: cap) {
                // Open on the phone all along without an answer: time out, and say why.
                self.expire(item, reason: ViewingPause.capNote(phoneName: pause.phoneName, cap: cap))
            } else {
                // The pause stays on record, so a later open still counts against the
                // cap from the first one.
                self.changed()
            }
        }
        item.viewingTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, pause.endsAt(cap: cap, grace: Self.viewingGrace).timeIntervalSinceNow), execute: work)
    }

    /// High and critical actions get extra time to read before the clock runs out. The
    /// check finishes after the request arrived, so the time goes on the clock if it
    /// runs, or on the limit while the request still waits its turn.
    private func addSeverityTime(_ item: Item, _ assessment: RiskAssessment) {
        let extra = SeverityRules.extraTime(assessment.severity, config: config.classifier)
        guard extra > 0, let limit = item.timeLimit else { return }
        if let remaining = item.pausedRemaining {
            item.grantedSeconds += extra
            item.pausedRemaining = remaining + extra
        } else if let deadline = item.deadline {
            item.grantedSeconds += extra
            item.deadline = item.capped(deadline.addingTimeInterval(extra))
        } else {
            item.timeLimit = limit + extra
        }
    }

    /// Approving needs the stronger shortcut (⇧⌘↩ by default): auto mode never allows
    /// the call, or the risk check says it is critical.
    func needsStrongApprove(_ item: Item) -> Bool {
        item.isHardDeny || SeverityRules.needsStrongApprove(item.risk.assessment?.severity, config: config.classifier)
    }

    /// "More time": adds `extendBy`, or `seconds` when given, to the clock, running or paused.
    func extendTime(by seconds: Double? = nil) {
        guard let item = current, item.timeLimit != nil else { return }
        let added = seconds ?? config.extendBy
        item.grantedSeconds += added
        if let remaining = item.pausedRemaining {
            item.pausedRemaining = remaining + added
        } else if let deadline = item.deadline {
            item.deadline = item.capped(deadline.addingTimeInterval(added))
        }
        changed()
    }

    /// Ends the wait of a secret input: the user enters it later, from the history, and
    /// it reaches Claude as a late answer. False when the request does not offer it.
    @discardableResult
    func enterLater(_ item: Item) -> Bool {
        guard item.request.offersEnterLater, item.lateEntryID == nil else { return false }
        respond(item, StewResponse(status: .later, note: StewResponse.laterNote))
        return true
    }

    /// ⌘↩ on an input: sends what is typed when it fits the pattern, else nothing.
    private func submitInput(_ item: Item, _ input: InputRequest) {
        guard case .valid(let text) = input.check(item.inputText) else { return }
        respond(item, StewResponse(status: .answered, text: text))
    }

    func setHotkeyFailures(_ failures: [Shortcut]) {
        if failures != hotkeyFailures { hotkeyFailures = failures }
    }

    func perform(_ action: HotkeyAction) {
        if let historyPreview, !historyPreview.allows(action) { return }
        if action == .dismissAll {
            // Needs items are things to do, not questions: dismissing everything parks
            // them, the same as "Not now", instead of declining them.
            for item in items {
                if item.isNeeds { park(item) } else { respond(item, StewResponse(status: .dismissed, risk: item.risk.assessment)) }
            }
            return
        }
        guard let item = current else { return }
        let note = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (item.request.prompt, action) {
        case (_, .extend):
            extendTime()
        case (.needs, .dismiss):
            park(item)
        case (.needs, .approve):
            if let id = item.needsID { answerNeeds(id: id, answerIndex: nil, note: note.isEmpty ? nil : note) }
        case (.needs, .deny):
            if let id = item.needsID { finishNeeds(id: id, outcome: .dismissed, status: .dismissed, note: note.isEmpty ? nil : note) }
        case (.needs, .other):
            setTextMode(!textMode)
        case (_, .dismiss):
            respond(item, StewResponse(status: .dismissed, note: note.isEmpty ? nil : note, risk: item.risk.assessment))
        case (.permission, .approve):
            let grant = grantMode ? grantChoice(for: item, duration: .hour) : nil
            respond(item, StewResponse(status: .approved, note: note.isEmpty ? nil : note, risk: item.risk.assessment, grant: grant))
        case (.permission, .grant):
            guard let blocked = item.blocked, !blocked.grantScopes.isEmpty else { return }
            grantMode.toggle()
            grantSelection = 0
            if grantMode { textMode = false }
            changed()
        case (.permission, .deny):
            respond(item, StewResponse(status: .denied, note: note.isEmpty ? nil : note, risk: item.risk.assessment))
        case (.permission, .other), (.question, .other), (.input, .other):
            setTextMode(!textMode)
        case (.input(let input), .submit):
            submitInput(item, input)
        case (.input(let input), .enterSoon):
            guard input.secret else { return }
            extendTime(by: InputRequest.enterSoonSeconds)
        case (.input, .enterLater):
            enterLater(item)
        case (.notify(let notify), .approve):
            respond(item, StewResponse(status: .acknowledged))
            switch notify.action {
            case .openHistory: openHistory(missedOnly: true)
            case .installUpdate: onInstallUpdate?()
            case nil: break
            }
        case (.question, .submit):
            guard var flow = item.flow else { return }
            let typedQuestion = flow.index
            let outcome = textMode ? flow.answerOther(draft) : flow.submitCurrent()
            item.flow = flow
            // The field stays open only while the typed question itself still has no answer.
            if textMode, outcome != .stay, outcome != .missing(typedQuestion) {
                draft = ""
                setTextMode(false)
            }
            finishIfComplete(item, outcome)
        case (.question, .next):
            item.flow?.next()
            item.questionNotice = nil
            changed()
        case (.question, .previous):
            item.flow?.previous()
            item.questionNotice = nil
            changed()
        default:
            break
        }
    }

    func grantAlways() {
        guard grantMode, let item = current, let grant = grantChoice(for: item, duration: .always) else { return }
        let note = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        respond(item, StewResponse(status: .approved, note: note.isEmpty ? nil : note, grant: grant))
    }

    private func grantChoice(for item: Item, duration: GrantChoice.Duration) -> GrantChoice? {
        guard let scopes = item.blocked?.grantScopes, scopes.indices.contains(grantSelection) else { return nil }
        return GrantChoice(scope: scopes[grantSelection], duration: duration)
    }

    func perform(_ panelAction: PanelAction) {
        switch panelAction {
        case .action(let action): perform(action)
        case .option(let index): choose(option: index)
        case .grantAlways: grantAlways()
        }
    }

    func openApprovals() {
        onOpenSettings?(.approvals)
    }

    /// The settings window saved a change: pick it up and re-register the keys.
    func configChanged() {
        reloadConfigIfChanged()
        changed()
        menuBarChanged()
    }

    func choose(option index: Int) {
        if historyPreview == .ended { return }
        if let item = current, item.isNeeds {
            let note = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = item.needsID { answerNeeds(id: id, answerIndex: index, note: note.isEmpty ? nil : note) }
            return
        }
        if grantMode {
            guard let scopes = current?.blocked?.grantScopes, scopes.indices.contains(index) else { return }
            grantSelection = index
            changed()
            return
        }
        guard let item = current, var flow = item.flow else { return }
        let outcome = flow.choose(index)
        item.flow = flow
        if textMode, !flow.current.multiSelect { setTextMode(false) }
        finishIfComplete(item, outcome)
    }

    func goToQuestion(_ index: Int) {
        current?.flow?.go(to: index)
        current?.questionNotice = nil
        changed()
    }

    /// Sends the answers once every question has one. Otherwise the panel shows what is
    /// missing, so Submit and ⌘↩ never do nothing.
    private func finishIfComplete(_ item: Item, _ outcome: QuestionFlow.Outcome) {
        guard let flow = item.flow else { return }
        if case .missing(let questionIndex) = outcome {
            item.questionNotice = flow.missingMessage(questionIndex)
        } else {
            item.questionNotice = nil
        }
        if outcome == .complete {
            let annotations = flow.annotations()
            respond(item, StewResponse(status: .answered, answers: flow.answers(), annotations: annotations.isEmpty ? nil : annotations))
        } else {
            changed()
        }
    }

    func setTextMode(_ enabled: Bool) {
        guard textMode != enabled, !(enabled && historyPreview == .ended) else { return }
        textMode = enabled
        // A request that arrived while the user typed on a needs item goes ahead of it now.
        if !enabled { arrangeQueue() }
        changed()
    }

    /// The shortcuts that make sense for what is on screen now.
    func activeBindings() -> [(Shortcut, PanelAction)] {
        let bindings = panelBindings()
        guard let historyPreview else { return bindings }
        return bindings.filter { _, panelAction in
            switch panelAction {
            case .action(let action): historyPreview.allows(action)
            case .option, .grantAlways: historyPreview != .ended
            }
        }
    }

    private func panelBindings() -> [(Shortcut, PanelAction)] {
        guard let item = current else { return [] }
        var bindings: [(Shortcut, PanelAction)] = [(keymap[.dismiss], .action(.dismiss))]
        if items.count > 1 { bindings.append((keymap[.dismissAll], .action(.dismissAll))) }
        switch item.request.prompt {
        case .permission:
            if item.timeLimit != nil, !item.typedOnMac { bindings.append((keymap[.extend], .action(.extend))) }
            if grantMode, let scopes = item.blocked?.grantScopes {
                for index in scopes.indices {
                    bindings.append((keymap.options[index], .option(index)))
                }
                bindings += [
                    (keymap[.approve], .action(.approve)),
                    (keymap[.approve].adding(keymap.hardDenyExtra), .grantAlways),
                    (keymap[.grant], .action(.grant)),
                ]
                break
            }
            let approve = needsStrongApprove(item) ? keymap[.approve].adding(keymap.hardDenyExtra) : keymap[.approve]
            bindings += [(approve, .action(.approve)), (keymap[.deny], .action(.deny)), (keymap[.other], .action(.other))]
            if let blocked = item.blocked, !blocked.grantScopes.isEmpty {
                bindings.append((keymap[.grant], .action(.grant)))
            }
        case .notify:
            bindings.append((keymap[.approve], .action(.approve)))
        case .needs(let needs):
            for index in needs.answers.indices.prefix(NeedsRequest.maxAnswers) {
                bindings.append((keymap.options[index], .option(index)))
            }
            bindings += [(keymap[.approve], .action(.approve)), (keymap[.deny], .action(.deny)), (keymap[.other], .action(.other))]
        case .question:
            guard let flow = item.flow else { break }
            for index in flow.current.options.indices {
                bindings.append((keymap.options[index], .option(index)))
            }
            bindings += [(keymap[.other], .action(.other)), (keymap[.submit], .action(.submit))]
            if item.timeLimit != nil, !item.typedOnMac { bindings.append((keymap[.extend], .action(.extend))) }
            if flow.questions.count > 1 {
                bindings += [(keymap[.next], .action(.next)), (keymap[.previous], .action(.previous))]
            }
        case .input(let input):
            bindings += [(keymap[.other], .action(.other)), (keymap[.submit], .action(.submit))]
            if item.timeLimit != nil {
                bindings.append((keymap[.extend], .action(.extend)))
                if input.secret { bindings.append((keymap[.enterSoon], .action(.enterSoon))) }
            }
            if item.request.offersEnterLater, item.lateEntryID == nil {
                bindings.append((keymap[.enterLater], .action(.enterLater)))
            }
        }
        return bindings
    }

    /// Changes only when the set of live shortcuts changes, so typing in the reply
    /// field does not re-register hotkeys on every keystroke.
    var bindingSignature: String {
        activeBindings().map { "\($0.0)" }.joined(separator: " ")
    }
}

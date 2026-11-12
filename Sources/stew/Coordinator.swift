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

    /// The caller's hard ceiling, such as Claude Code's hook timeout.
    var latestDeadline: Date? { request.maxWait.map { received.addingTimeInterval($0) } }

    func capped(_ date: Date) -> Date {
        latestDeadline.map { min(date, $0) } ?? date
    }
    @Published var flow: QuestionFlow?
    @Published var risk: RiskState = .off
    /// stew's own notice, such as the return summary: kept out of the history.
    var isInternal = false
    /// Option under the mouse, so its preview shows.
    @Published var hoveredOption: Int?
    /// For a needs item: its id in needs.json.
    var needsID: String?

    var isNeeds: Bool {
        if case .needs = request.prompt { return true }
        return false
    }

    init(request: StewRequest, connection: Connection?) {
        self.request = request
        self.connection = connection
        if case .question(let set) = request.prompt {
            flow = QuestionFlow(questions: set.questions)
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

final class Coordinator: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var textMode = false
    /// The "Allow more…" view of a blocked call, with the scope picked in it.
    @Published private(set) var grantMode = false
    @Published private(set) var grantSelection = 0
    @Published var draft = ""
    @Published private(set) var keymap: Keymap
    @Published private(set) var configError: String?
    @Published private(set) var hotkeyFailures: [Shortcut] = []
    private(set) var config: StewConfig
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
    /// Opens the settings window on History; true shows only missed requests.
    var onOpenHistory: ((Bool) -> Void)?
    /// `stew update`: check and install now, then reply with the outcome.
    var onUpdate: ((@escaping (UpdateOutcome) -> Void) -> Void)?
    /// Open needs items. In memory only until the daemon gives it needs.json.
    var needsStore = NeedsStore(path: nil)
    /// Called whenever the open needs items change, for the menu bar.
    var onNeedsChange: (([NeedsItem]) -> Void)?
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
            onOpenHistory?(control == "history missed")
        case "update":
            guard let onUpdate else {
                connection.send((try? Wire.encode(UpdateOutcome(status: .checkFailed, message: "this daemon cannot update"))) ?? Data())
                return
            }
            onUpdate { outcome in connection.send((try? Wire.encode(outcome)) ?? Data()) }
        case _ where control.hasPrefix("needs "):
            connection.send(handleNeeds(control: String(control.dropFirst("needs ".count))))
        default:
            if Paths.headless, let reply = handleTestControl(control) {
                connection.send(Data((reply + "\n").utf8))
                return
            }
            connection.send(Data("unknown control \(control)\n".utf8))
        }
    }

    func enqueue(_ request: StewRequest, connection: Connection?) {
        reloadConfigIfChanged()
        if case .needs(let needs) = request.prompt {
            addNeeds(needs, request: request, connection: connection)
            return
        }
        let item = Item(request: request, connection: connection)
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
                case .success(let assessment): item.risk = .done(assessment)
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
        case "answered":
            let answered = NeedsBook.answeredBy(sessionID: argument, in: needsStore.items)
            for record in answered {
                finishNeeds(id: record.id, outcome: .answeredInSession, status: .resolved, note: nil)
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

    /// Puts an open needs item in the panel queue, behind everything else.
    private func queueNeeds(_ record: NeedsItem) {
        guard !items.contains(where: { $0.needsID == record.id }) else { return }
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
            queueNeeds(record)
        }
        needsChanged()
    }

    /// Ends a needs item for good: history entry, answer for a waiting caller, gone from
    /// the panel and needs.json.
    @discardableResult
    private func finishNeeds(id: String, outcome: HistoryEntry.Outcome, status: StewStatus, note: String?) -> Bool {
        guard let record = needsStore.remove(id) else { return false }
        history?.append(HistoryEntry.record(record, outcome: outcome, note: note, ended: Date()))
        answerWaiter(id, StewResponse(status: status, note: note, id: id))
        if let panelItem = items.first(where: { $0.needsID == id }) {
            remove(panelItem)
        } else {
            changed()
        }
        needsChanged()
        return true
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
        onNeedsChange?(needsStore.items)
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
            draft = argument
        case "returned":
            // Simulates the user coming back after `argument` seconds away.
            userReturned(awaySince: Date().addingTimeInterval(-(Double(argument) ?? 0)))
        case "open":
            // A click on a needs item in the menu bar.
            openNeeds(id: argument)
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
        let bindings = activeBindings().map { "\($0.0)" }.joined(separator: " ")
        var clockState = "none"
        if let deadline = current?.deadline { clockState = "running:\(Int(deadline.timeIntervalSinceNow.rounded()))" }
        if let remaining = current?.pausedRemaining { clockState = "paused:\(Int(remaining.rounded()))" }
        let needsState = "needs=\(needsStore.items.count) parked=\(needsStore.items.filter(\.parked).count) front=\(current?.needsID ?? "-")"
        return "items=\(items.count) kind=\(current?.request.prompt.kind ?? "none") question=\(current?.flow?.index ?? -1) text=\(textMode) grant=\(grantMode):\(grantSelection) clock=\(clockState) risk=\(risk) confetti=\(celebrations) \(needsState) keys=\(bindings)"
    }

    /// Puts a prepared item on screen without a caller or risk check (snapshots).
    func show(_ item: Item) {
        item.timeLimit = item.timeLimit ?? item.request.timeLimit(defaultTimeout: config.responseTimeout)
        items.append(item)
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

    func respond(_ item: Item, _ response: StewResponse) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        if config.celebrates(response, to: item.request.prompt) {
            // Before the item goes, so the panel is still where the user looked.
            celebrations += 1
            onCelebrate?()
        }
        record(item, response)
        item.connection?.send((try? Wire.encode(response)) ?? Data())
        item.connection = nil
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
        for item in items where !item.isNeeds {
            let response = StewResponse(status: .dismissed, note: "stew daemon stopped")
            record(item, response)
            item.connection?.send((try? Wire.encode(response)) ?? Data())
        }
        items = []
        history?.flush()
    }

    /// No response means the caller went away before an answer.
    private func record(_ item: Item, _ response: StewResponse?) {
        // Needs items record their own ending in finishNeeds.
        guard let history, !item.isInternal, !item.isNeeds else { return }
        history.append(HistoryEntry.record(item.request, received: item.received, response: response, ended: Date()))
    }

    /// The user is back after being away since `awaySince`. One notice for every
    /// request that timed out meanwhile and every open needs item; nothing when there is
    /// neither. Parked needs items come back into the panel, each one only once.
    func userReturned(awaySince: Date) {
        guard let history else { return }
        let missed = History.missed(history.read(), since: awaySince)
        for record in needsStore.items where record.parked && !record.reminded {
            needsStore.update(record.id) { item in
                item.parked = false
                item.reminded = true
            }
            queueNeeds(record)
            needsChanged()
        }
        guard let notice = ReturnSummary.notice(missedCount: missed.count, needsCount: needsStore.items.count) else { return }
        let item = Item(request: StewRequest(session: SessionInfo(name: "stew"), prompt: .notify(notice), wait: false), connection: nil)
        item.isInternal = true
        items.append(item)
        arrangeQueue()
        changed()
    }

    private func changed() {
        syncTimer()
        onChange?()
        if isIdle { onIdle?() }
    }

    /// The clock runs only for the request on screen, and pauses while the user types
    /// a note or picks a grant, so taking care over an answer never times it out.
    private func syncTimer() {
        guard let item = current, let limit = item.timeLimit else { return }
        if item.deadline == nil && item.pausedRemaining == nil {
            item.grantedSeconds = limit
            item.deadline = item.capped(Date().addingTimeInterval(limit))
        }
        let shouldPause = textMode || grantMode
        if shouldPause, let deadline = item.deadline {
            item.pausedRemaining = max(0, deadline.timeIntervalSinceNow)
            item.deadline = nil
        } else if !shouldPause, let remaining = item.pausedRemaining {
            item.pausedRemaining = nil
            item.deadline = item.capped(Date().addingTimeInterval(remaining))
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

    private func expire(_ item: Item) {
        respond(item, StewResponse(status: .timeout, note: item.request.timeoutNote(after: item.grantedSeconds), risk: item.risk.assessment))
    }

    /// "More time": adds `extendBy` to the clock, running or paused.
    func extendTime() {
        guard let item = current, item.timeLimit != nil else { return }
        item.grantedSeconds += config.extendBy
        if let remaining = item.pausedRemaining {
            item.pausedRemaining = remaining + config.extendBy
        } else if let deadline = item.deadline {
            item.deadline = item.capped(deadline.addingTimeInterval(config.extendBy))
        }
        changed()
    }

    func setHotkeyFailures(_ failures: [Shortcut]) {
        if failures != hotkeyFailures { hotkeyFailures = failures }
    }

    func perform(_ action: HotkeyAction) {
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
            if let id = item.needsID { finishNeeds(id: id, outcome: .done, status: .done, note: note.isEmpty ? nil : note) }
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
        case (.permission, .other), (.question, .other):
            setTextMode(!textMode)
        case (.notify(let notify), .approve):
            respond(item, StewResponse(status: .acknowledged))
            if notify.action == .openHistory { onOpenHistory?(true) }
        case (.question, .submit):
            guard var flow = item.flow else { return }
            let outcome = textMode ? flow.answerOther(draft) : flow.submitCurrent()
            item.flow = flow
            if textMode, outcome != .stay {
                draft = ""
                setTextMode(false)
            }
            finishIfComplete(item, outcome)
        case (.question, .next):
            item.flow?.next()
            changed()
        case (.question, .previous):
            item.flow?.previous()
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
    }

    func choose(option index: Int) {
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
        changed()
    }

    private func finishIfComplete(_ item: Item, _ outcome: QuestionFlow.Outcome) {
        guard let flow = item.flow else { return }
        if outcome == .complete {
            let annotations = flow.annotations()
            respond(item, StewResponse(status: .answered, answers: flow.answers(), annotations: annotations.isEmpty ? nil : annotations))
        } else {
            changed()
        }
    }

    func setTextMode(_ enabled: Bool) {
        guard textMode != enabled else { return }
        textMode = enabled
        // A request that arrived while the user typed on a needs item goes ahead of it now.
        if !enabled { arrangeQueue() }
        changed()
    }

    /// The shortcuts that make sense for what is on screen now.
    func activeBindings() -> [(Shortcut, PanelAction)] {
        guard let item = current else { return [] }
        var bindings: [(Shortcut, PanelAction)] = [(keymap[.dismiss], .action(.dismiss))]
        if items.count > 1 { bindings.append((keymap[.dismissAll], .action(.dismissAll))) }
        switch item.request.prompt {
        case .permission:
            if item.timeLimit != nil { bindings.append((keymap[.extend], .action(.extend))) }
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
            let approve = item.isHardDeny ? keymap[.approve].adding(keymap.hardDenyExtra) : keymap[.approve]
            bindings += [(approve, .action(.approve)), (keymap[.deny], .action(.deny)), (keymap[.other], .action(.other))]
            if let blocked = item.blocked, !blocked.grantScopes.isEmpty {
                bindings.append((keymap[.grant], .action(.grant)))
            }
        case .notify:
            bindings.append((keymap[.approve], .action(.approve)))
        case .needs:
            bindings += [(keymap[.approve], .action(.approve)), (keymap[.deny], .action(.deny)), (keymap[.other], .action(.other))]
        case .question:
            guard let flow = item.flow else { break }
            for index in flow.current.options.indices {
                bindings.append((keymap.options[index], .option(index)))
            }
            bindings += [(keymap[.other], .action(.other)), (keymap[.submit], .action(.submit))]
            if item.timeLimit != nil { bindings.append((keymap[.extend], .action(.extend))) }
            if flow.questions.count > 1 {
                bindings += [(keymap[.next], .action(.next)), (keymap[.previous], .action(.previous))]
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

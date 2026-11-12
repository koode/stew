import AppKit
import Foundation
import StewCore

enum RiskState: Equatable {
    case off
    case checking
    case done(RiskAssessment)
    case failed(String)

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
    var deadline: Date?
    var timer: DispatchWorkItem?
    @Published var flow: QuestionFlow?
    @Published var risk: RiskState = .off
    /// Option under the mouse, so its preview shows.
    @Published var hoveredOption: Int?

    init(request: StewRequest, connection: Connection?) {
        self.request = request
        self.connection = connection
        if case .question(let set) = request.prompt {
            flow = QuestionFlow(questions: set.questions)
        }
        if let timeout = request.timeout {
            deadline = Date().addingTimeInterval(timeout)
        }
    }

    var isHardDeny: Bool { risk.assessment?.verdict == .hardDeny }
}

final class Coordinator: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var textMode = false
    @Published var draft = ""
    @Published private(set) var keymap: Keymap
    @Published private(set) var configError: String?
    @Published private(set) var hotkeyFailures: [String] = []
    private(set) var config: StewConfig
    private var configModified: Date?
    var onChange: (() -> Void)?
    var onStop: (() -> Void)?

    var current: Item? { items.first }

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
        let item = Item(request: request, connection: connection)
        if case .notify = request.prompt, !request.wait {
            // The caller only wants it shown; the panel keeps it until dismissed.
            connection?.send((try? Wire.encode(StewResponse(status: .shown))) ?? Data())
            item.connection = nil
        }
        if let timeout = request.timeout {
            let timer = DispatchWorkItem { [weak self, weak item] in
                guard let self, let item else { return }
                self.respond(item, StewResponse(status: .timeout, risk: item.risk.assessment))
            }
            item.timer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
        }
        if case .permission(let permission) = request.prompt, config.classifier.enabled {
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
        if wasEmpty, let sound = config.sound, !sound.isEmpty {
            NSSound(named: NSSound.Name(sound))?.play()
        }
        changed()
    }

    /// Simulated input for end-to-end tests: "press approve", "choose 2", "type text", "state".
    private func handleTestControl(_ control: String) -> String? {
        let parts = control.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "press":
            guard let action = HotkeyAction(rawValue: argument) else { return "unknown action" }
            perform(action)
        case "choose":
            guard let number = Int(argument) else { return "bad option" }
            choose(option: number - 1)
        case "type":
            draft = argument
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
        case .off, nil: risk = "off"
        }
        let bindings = activeBindings().map { "\($0.0)" }.joined(separator: " ")
        return "items=\(items.count) kind=\(current?.request.prompt.kind ?? "none") question=\(current?.flow?.index ?? -1) text=\(textMode) risk=\(risk) keys=\(bindings)"
    }

    /// Puts a prepared item on screen without a caller or risk check (snapshots).
    func show(_ item: Item) {
        items.append(item)
        changed()
    }

    func connectionClosed(_ connectionID: UUID) {
        guard let item = items.first(where: { $0.connection?.id == connectionID }) else { return }
        item.connection = nil
        remove(item)
    }

    func respond(_ item: Item, _ response: StewResponse) {
        guard items.contains(where: { $0.id == item.id }) else { return }
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
            draft = ""
        }
        changed()
    }

    func dismissAllForShutdown() {
        for item in items {
            item.connection?.send((try? Wire.encode(StewResponse(status: .dismissed, note: "stew daemon stopped"))) ?? Data())
        }
        items = []
    }

    private func changed() {
        onChange?()
    }

    func setHotkeyFailures(_ failures: [String]) {
        if failures != hotkeyFailures { hotkeyFailures = failures }
    }

    func perform(_ action: HotkeyAction) {
        if action == .dismissAll {
            for item in items { respond(item, StewResponse(status: .dismissed, risk: item.risk.assessment)) }
            return
        }
        guard let item = current else { return }
        let note = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (item.request.prompt, action) {
        case (_, .dismiss):
            respond(item, StewResponse(status: .dismissed, note: note.isEmpty ? nil : note, risk: item.risk.assessment))
        case (.permission, .approve):
            respond(item, StewResponse(status: .approved, note: note.isEmpty ? nil : note, risk: item.risk.assessment))
        case (.permission, .deny):
            respond(item, StewResponse(status: .denied, note: note.isEmpty ? nil : note, risk: item.risk.assessment))
        case (.permission, .other), (.question, .other):
            setTextMode(!textMode)
        case (.notify, .approve):
            respond(item, StewResponse(status: .acknowledged))
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

    func choose(option index: Int) {
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
        changed()
    }

    /// The shortcuts that make sense for what is on screen now.
    func activeBindings() -> [(Shortcut, HotkeyAction?, Int?)] {
        guard let item = current else { return [] }
        var bindings: [(Shortcut, HotkeyAction?, Int?)] = [(keymap[.dismiss], .dismiss, nil)]
        if items.count > 1 { bindings.append((keymap[.dismissAll], .dismissAll, nil)) }
        switch item.request.prompt {
        case .permission:
            let approve = item.isHardDeny ? keymap[.approve].adding(keymap.hardDenyExtra) : keymap[.approve]
            bindings += [(approve, .approve, nil), (keymap[.deny], .deny, nil), (keymap[.other], .other, nil)]
        case .notify:
            bindings.append((keymap[.approve], .approve, nil))
        case .question:
            guard let flow = item.flow else { break }
            for index in flow.current.options.indices {
                bindings.append((keymap.options[index], nil, index))
            }
            bindings += [(keymap[.other], .other, nil), (keymap[.submit], .submit, nil)]
            if flow.questions.count > 1 {
                bindings += [(keymap[.next], .next, nil), (keymap[.previous], .previous, nil)]
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

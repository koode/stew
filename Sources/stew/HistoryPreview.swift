import AppKit
import SwiftUI
import StewCore

/// The selected request in History, drawn with the panel's own views by a coordinator
/// of its own. One that can still be answered late keeps the panel's buttons; its
/// answers go to the daemon's coordinator as a late answer. An ended one shows how it
/// ended instead.
final class HistoryPreview {
    let entryID: UUID
    let mode: HistoryPreviewMode
    let coordinator: Coordinator
    /// Changes when the entry gets a late answer or stops being answerable, so the
    /// preview is built again.
    let signature: String

    init(entry: HistoryEntry, waiting: LateRequest?, onAnswer: @escaping (UUID, StewResponse) -> Bool) {
        entryID = entry.id
        coordinator = Coordinator()
        signature = Self.signature(entry, live: waiting != nil)
        let item: Item
        if let waiting {
            var request = waiting.request
            request.timeout = 0
            request.maxWait = nil
            mode = .late(ended: "\(entry.outcome.label(for: entry.agent)) \(SettingsDate.text(entry.ended))")
            item = Item(request: request, connection: nil)
            item.lateEntryID = entry.id
            coordinator.onPreviewAnswer = onAnswer
        } else {
            mode = .ended
            item = Item(request: entry.previewRequest, connection: nil)
            Self.restoreAnswer(of: entry, on: item)
        }
        if let blocked = item.blocked { item.risk = .blocked(blocked) }
        coordinator.showPreview(item, mode: mode)
    }

    static func signature(_ entry: HistoryEntry, live: Bool) -> String {
        "\(entry.id) \(live) \(entry.late?.answered.timeIntervalSince1970 ?? 0)"
    }

    /// The answer as the panel showed it when it was sent: the chosen options, the typed
    /// text, or dots for a secret, which stew never keeps.
    private static func restoreAnswer(of entry: HistoryEntry, on item: Item) {
        switch item.request.prompt {
        case .question(let set):
            item.flow = QuestionFlow.restoring(questions: set.questions, answers: entry.givenAnswers ?? [:])
        case .input(let input):
            if input.secret {
                item.inputText = entry.secretEntered ? secretStandIn : ""
            } else {
                item.inputText = entry.late?.text ?? entry.text ?? ""
            }
        case .permission, .notify, .needs:
            break
        }
    }

    /// Any text: the field shows a secret as a fixed row of dots.
    private static let secretStandIn = "secret"

    /// The panel's shortcut for `event`, when the preview shows one, performed.
    func perform(_ event: NSEvent, layout: [Character: UInt16]) -> Bool {
        let modifiers = Self.modifiers(event.modifierFlags)
        for (shortcut, action) in coordinator.activeBindings()
        where shortcut.modifiers == modifiers && KeyCodes.code(for: shortcut.key, layout: layout) == event.keyCode {
            coordinator.perform(action)
            return true
        }
        return false
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

/// The right side of History: the selected request as the panel showed it, then what
/// the panel does not show (when it was asked and ended, what Claude was told).
struct HistoryPreviewPane: View {
    @ObservedObject var model: HistoryModel
    let entry: HistoryEntry
    let preview: HistoryPreview
    /// Whether the preview has the keyboard, so the panel's shortcuts apply.
    var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            // The panel's width, or less in a narrow window. What follows the card lines
            // up with it.
            let width = min(RootView.width(for: preview.coordinator.current), max(geometry.size.width - 2 * Self.inset, 360))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PreviewCard(coordinator: preview.coordinator, entry: entry, width: width)
                    if case .late = preview.mode {
                        Hint(lateHint)
                    }
                    if let message = model.message {
                        Notice(message.tone, message.text)
                    }
                    HistoryDetails(entry: entry, model: model)
                }
                .frame(width: width, alignment: .leading)
                .padding(Self.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static let inset: CGFloat = 20

    private var lateHint: String {
        let keys = focused ? "" : " Click the request to use the panel's keys."
        let agent = entry.agent.name
        if entry.outcome == .later {
            return "\(agent) gets the secret at its next step. stew keeps it in memory only until then.\(keys)"
        }
        return entry.secret == true
            ? "It timed out, so \(agent) gets your answer at its next step. stew keeps the secret in memory only until then.\(keys)"
            : "It timed out, so \(agent) gets your answer at its next step.\(keys)"
    }
}

/// The panel's card: the same views, background and width as the floating panel, and
/// for an ended request the outcome where the buttons were.
private struct PreviewCard: View {
    @ObservedObject var coordinator: Coordinator
    let entry: HistoryEntry
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = coordinator.current {
                ItemCard(item: item, coordinator: coordinator, interactive: true)
            } else {
                // Answered a moment ago: the history reloads with the late outcome.
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            if !coordinator.showsButtons {
                OutcomeBanner(entry: entry)
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .environment(\.panelTextWidth, width - 32)
        .modifier(PanelBackground(glass: false))
    }
}

/// How an ended request ended, where the panel had its buttons.
struct OutcomeBanner: View {
    let entry: HistoryEntry

    var body: some View {
        let outcome = entry.shownOutcome
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: outcome.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(outcome.tone)
                .frame(width: 14)
            Text(entry.outcomeLine(timeText: SettingsDate.text))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(outcome.tone.opacity(0.12)))
    }
}

/// What History knows beyond the panel: times, the risk, the answers, what Claude was
/// told, a late answer and its delivery, and "Allow next time…" for a missed blocked call.
struct HistoryDetails: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Asked", SettingsDate.text(entry.received))
                    row(entry.missed ? "Timed out" : "Ended", SettingsDate.text(entry.ended))
                    if let severity = entry.severity {
                        row("Risk", [severity.label, entry.reversibility].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let answers = entry.answers, !answers.isEmpty {
                        row("Answers", Self.answerText(answers))
                    }
                    if let text = entry.text {
                        row("Answer", text)
                    } else if entry.secret == true, entry.outcome == .answered {
                        row("Answer", Self.secretEntered)
                    }
                    if let grant = entry.grant {
                        row("Allowed", Self.grantText(grant))
                    }
                    // The agent hears about a needs item only when it waited for it, so
                    // the row shows the user's note instead.
                    if entry.kind == "needs" {
                        if let answer = entry.answer, !answer.isEmpty { row("Answer", answer) }
                        if let note = entry.note, !note.isEmpty { row("Note", note) }
                    } else {
                        row("\(entry.agent.name) was told", toldAgent)
                    }
                    if let late = entry.late {
                        row("Answered late", SettingsDate.text(late.answered))
                        if let answers = late.answers, !answers.isEmpty {
                            row("Answers", Self.answerText(answers))
                        }
                        if let text = late.text {
                            row("Answer", text)
                        } else if entry.secret == true, late.outcome == .answered {
                            row("Answer", Self.secretEntered)
                        }
                        if let grant = late.grant {
                            row("Allowed", Self.grantText(grant))
                        }
                        row("\(entry.agent.name) is told", late.message)
                        if let delivery = model.deliveryText(entry) {
                            row("Delivery", delivery)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if entry.missed, let blocked = entry.blocked, !blocked.grantScopes.isEmpty {
                SettingRow(hint: "In \(URL(fileURLWithPath: blocked.projectRoot).lastPathComponent), without asking.") {
                    Menu("Allow next time…") {
                        ForEach(blocked.grantScopes, id: \.self) { scope in
                            Section(Self.scopeTitle(scope)) {
                                Button("For 1 hour") { model.allow(scope, .hour, for: blocked) }
                                Button("Always") { model.allow(scope, .always, for: blocked) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    /// Shown for a secret instead of its value, which stew never stores.
    static let secretEntered = "A secret was entered. stew does not keep it."

    private static func answerText(_ answers: [String: String]) -> String {
        answers.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: "\n")
    }

    private static func grantText(_ grant: GrantChoice) -> String {
        "\(grant.scope.value), \(grant.duration == .always ? "always" : "for 1 hour")"
    }

    /// The status the agent got, with the note that came with it.
    private var toldAgent: String {
        if let note = entry.note, !note.isEmpty {
            return "\(entry.outcome.label(for: entry.agent)): \(note)"
        }
        switch entry.outcome {
        case .callerGone: return "Nothing: the caller had stopped waiting."
        case .answered where entry.kind == "input": return entry.secret == true ? "The secret." : "The answer above."
        case .answered: return "The answers above."
        default: return "\(entry.outcome.label(for: entry.agent))."
        }
    }

    private static func scopeTitle(_ scope: GrantChoice.Scope) -> String {
        switch scope.kind {
        case .exact: "This command: \(scope.value)"
        case .pattern: "Commands that start like this: \(scope.value)"
        case .category: "Anything auto mode blocks as \(scope.value)"
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An AppKit view behind an area of SwiftUI, handed to `found`, so a click or a key can
/// be checked against the area and the window it is in.
struct AreaReader: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { found(view) }
    }
}

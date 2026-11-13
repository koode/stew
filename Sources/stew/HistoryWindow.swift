import AppKit
import SwiftUI
import StewCore

/// The History tab: every finished request, newest first, with what Claude was told.
final class HistoryModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var missedOnly = false
    @Published var selection: HistoryEntry.ID?
    @Published private(set) var message: String?
    @Published private(set) var keepDays = History.defaultKeepDays
    /// Timed-out requests that can still be answered, and the late answers given.
    @Published private(set) var mailbox = LateMailbox()
    /// "Answer now": shows the request in the panel again. False when it is too late.
    var onAnswerNow: ((UUID) -> Bool)?
    /// Sample entries for `stew snapshot`: reloading leaves them alone.
    private var isSample = false

    func showSample(_ entries: [HistoryEntry], missedOnly: Bool = false) {
        isSample = true
        self.entries = entries
        self.missedOnly = missedOnly
        selection = visible.first?.id
    }

    var visible: [HistoryEntry] { History.filtered(entries, missedOnly: missedOnly) }
    var selected: HistoryEntry? { entries.first { $0.id == selection } }

    func reload() {
        guard !isSample else { return }
        keepDays = loadConfig().0.historyDays
        entries = HistoryStore.readFile()
        mailbox = LateAnswerFile.read()
        if selection == nil || !visible.contains(where: { $0.id == selection }) {
            selection = visible.first?.id
        }
    }

    func canAnswerNow(_ entry: HistoryEntry) -> Bool {
        entry.answerableLater && entry.late == nil && mailbox.waiting(entry.id, now: Date()) != nil
    }

    func answerNow(_ entry: HistoryEntry) {
        if onAnswerNow?(entry.id) == true {
            message = "Shown in the panel. Claude gets your answer at its next step."
        } else {
            message = "This request can no longer be answered: it timed out more than a day ago."
            reload()
        }
    }

    /// Where a late answer is: waiting for the session's next step, or delivered.
    func deliveryText(_ entry: HistoryEntry) -> String? {
        guard entry.late != nil else { return nil }
        guard let answer = mailbox.answer(entry.id) else {
            return "No longer tracked: answers are kept for a day."
        }
        if let delivered = answer.delivered {
            return "Delivered \(HistoryEntry.timeText(delivered))\(answer.deliveredBy.map { ", at \($0)" } ?? "")."
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
            message = duration == .always ? "Allowed in \(project) from now on." : "Allowed in \(project) for 1 hour."
        } catch {
            message = "Could not allow it: \(error)"
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        SettingsPane(
            tab: .history,
            subtitle: "Requests from the last \(model.keepDays) days. Missed ones ran out of time while nobody answered, or are secrets you chose to enter later."
        ) {
            Toggle("Missed only", isOn: $model.missedOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if model.visible.isEmpty {
                    SettingsCard {
                        EmptyState(
                            symbol: model.missedOnly ? "clock.badge.exclamationmark" : "clock",
                            title: model.missedOnly ? "No missed requests" : "No requests yet",
                            message: model.missedOnly
                                ? "Requests that run out of time while nobody answers, and secrets you chose to enter later, show here."
                                : "Permission requests, questions and notifications show here once they finish."
                        )
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    SettingsCard {
                        Table(model.visible, selection: $model.selection) {
                            TableColumn("Time") { entry in
                                Text(HistoryEntry.timeText(entry.ended)).font(.system(size: 12)).monospacedDigit()
                            }
                            .width(min: 90, ideal: 100)
                            TableColumn("Session") { entry in
                                Text(entry.session).font(.system(size: 12)).lineLimit(1).help(entry.cwd ?? entry.session)
                            }
                            .width(min: 90, ideal: 130)
                            TableColumn("Request") { entry in
                                Text(entry.summary).font(.system(size: 12)).lineLimit(1).truncationMode(.tail).help(entry.summary)
                            }
                            .width(min: 160)
                            TableColumn("Risk") { entry in
                                if let severity = entry.severity { SeverityPill(severity: severity) }
                            }
                            .width(100)
                            TableColumn("Outcome") { entry in
                                OutcomePill(entry: entry)
                            }
                            .width(140)
                        }
                        .scrollContentBackground(.hidden)
                        .alternatingRowBackgrounds(.disabled)
                    }
                    .frame(minHeight: 160)
                    if let entry = model.selected {
                        SettingsCard {
                            ScrollView {
                                HistoryDetail(entry: entry, model: model)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            }
                        }
                        .frame(minHeight: 150, idealHeight: 200, maxHeight: 240)
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.inset)
            .padding(.top, 14)
            .padding(.bottom, SettingsMetrics.inset)
        }
        .onAppear { model.reload() }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in model.reload() }
    }
}

extension HistoryEntry {
    /// One date form for the whole tab, such as "Nov 12, 17:15".
    static func timeText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// One form for every outcome: a tinted capsule, the same size in every row. A late
/// answer shows as its own outcome, such as "Approved late", in that outcome's tone.
struct OutcomePill: View {
    let entry: HistoryEntry

    private var outcome: HistoryEntry.Outcome { entry.late?.outcome ?? entry.outcome }

    var body: some View {
        StatusPill(text: entry.outcomeLabel, tone: tone)
    }

    private var tone: Color {
        switch outcome {
        case .approved, .done: .green
        case .denied: .red
        case .answered, .acknowledged, .resolvedByClaude, .answeredInSession: .blue
        case .movedOn: .secondary
        case .timedOut, .later: .orange
        case .dismissed, .callerGone: .secondary
        }
    }
}

struct HistoryDetail: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.summary).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                Spacer()
                OutcomePill(entry: entry)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Session", entry.cwd.map { "\(entry.session) · \($0)" } ?? entry.session)
                row("Asked", HistoryEntry.timeText(entry.received))
                row("Ended", HistoryEntry.timeText(entry.ended))
                if let command = entry.command {
                    row("Command", command, monospaced: true)
                }
                if let severity = entry.severity {
                    row("Risk", [severity.label, entry.reversibility].compactMap { $0 }.joined(separator: " · "))
                }
                if let detail = entry.detail, !detail.isEmpty {
                    row(detailLabel, detail)
                }
                if let answers = entry.answers, !answers.isEmpty {
                    row("Answers", answers.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: "\n"))
                }
                if let text = entry.text {
                    row("Answer", text)
                } else if entry.secret == true, entry.outcome == .answered {
                    row("Answer", Self.secretEntered)
                }
                if let grant = entry.grant {
                    row("Allowed", "\(grant.scope.value), \(grant.duration == .always ? "always" : "for 1 hour")")
                }
                // Claude hears about a needs item only when it waited for it, so the
                // row shows the user's note instead.
                if entry.kind == "needs" {
                    if let answer = entry.answer, !answer.isEmpty { row("Answer", answer) }
                    if let note = entry.note, !note.isEmpty { row("Note", note) }
                } else {
                    row("Claude was told", toldClaude)
                }
                if let late = entry.late {
                    row("Answered late", HistoryEntry.timeText(late.answered))
                    if let answers = late.answers, !answers.isEmpty {
                        row("Answers", answers.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: "\n"))
                    }
                    if let text = late.text {
                        row("Answer", text)
                    } else if entry.secret == true, late.outcome == .answered {
                        row("Answer", Self.secretEntered)
                    }
                    if let grant = late.grant {
                        row("Allowed", "\(grant.scope.value), \(grant.duration == .always ? "always" : "for 1 hour")")
                    }
                    row("Claude is told", late.message)
                    if let delivery = model.deliveryText(entry) {
                        row("Delivery", delivery)
                    }
                }
            }
            if model.canAnswerNow(entry) {
                SettingRow(hint: entry.secret == true
                    ? "Shows it in the panel again. stew keeps the secret in memory only until Claude's next step picks it up."
                    : "Shows it in the panel again. Claude gets your answer at its next step.") {
                    Button("Answer now") { model.answerNow(entry) }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                }
            }
            if entry.missed, let blocked = entry.blocked, !blocked.grantScopes.isEmpty {
                SettingRow(hint: "In \(URL(fileURLWithPath: blocked.projectRoot).lastPathComponent), without asking.") {
                    Menu("Allow next time…") {
                        ForEach(blocked.grantScopes, id: \.self) { scope in
                            Section(scopeTitle(scope)) {
                                Button("For 1 hour") { model.allow(scope, .hour, for: blocked) }
                                Button("Always") { model.allow(scope, .always, for: blocked) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var detailLabel: String {
        switch entry.kind {
        case "question": "Questions"
        case "notify": "Message"
        case "needs": "Details"
        default: "Why"
        }
    }

    /// Shown for a secret instead of its value, which stew never stores.
    static let secretEntered = "A secret was entered. stew does not keep it."

    /// The status Claude got, with the note that came with it.
    private var toldClaude: String {
        if let note = entry.note, !note.isEmpty {
            return "\(entry.outcome.label): \(note)"
        }
        switch entry.outcome {
        case .callerGone: return "Nothing: the caller had stopped waiting."
        case .answered where entry.kind == "input": return entry.secret == true ? "The secret." : "The answer above."
        case .answered: return "The answers above."
        default: return "\(entry.outcome.label)."
        }
    }

    private func scopeTitle(_ scope: GrantChoice.Scope) -> String {
        switch scope.kind {
        case .exact: "This command: \(scope.value)"
        case .pattern: "Commands that start like this: \(scope.value)"
        case .category: "Anything auto mode blocks as \(scope.value)"
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

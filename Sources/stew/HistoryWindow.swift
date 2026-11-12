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

    var visible: [HistoryEntry] { History.filtered(entries, missedOnly: missedOnly) }
    var selected: HistoryEntry? { entries.first { $0.id == selection } }

    func reload() {
        keepDays = loadConfig().0.historyDays
        entries = HistoryStore.readFile()
        if selection == nil || !visible.contains(where: { $0.id == selection }) {
            selection = visible.first?.id
        }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Requests from the last \(model.keepDays) days. Missed ones ran out of time while nobody answered.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Toggle("Missed only", isOn: $model.missedOnly)
            }
            if model.visible.isEmpty {
                Spacer()
                Text(model.missedOnly ? "No missed requests." : "No requests yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Table(model.visible, selection: $model.selection) {
                    TableColumn("Time") { entry in
                        Text(HistoryEntry.timeText(entry.ended)).monospacedDigit()
                    }
                    .width(min: 90, ideal: 100)
                    TableColumn("Session") { entry in
                        Text(entry.session).lineLimit(1).help(entry.cwd ?? entry.session)
                    }
                    .width(min: 90, ideal: 130)
                    TableColumn("Request") { entry in
                        Text(entry.summary).lineLimit(1).truncationMode(.tail).help(entry.summary)
                    }
                    .width(min: 160)
                    TableColumn("Outcome") { entry in
                        OutcomePill(outcome: entry.outcome)
                    }
                    .width(140)
                }
                .frame(minHeight: 160)
                if let entry = model.selected {
                    Divider()
                    ScrollView {
                        HistoryDetail(entry: entry, model: model)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 150, idealHeight: 200)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 300)
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

/// One form for every outcome: a tinted capsule, the same size in every row.
struct OutcomePill: View {
    let outcome: HistoryEntry.Outcome

    var body: some View {
        Text(outcome.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.opacity(0.15)))
            .fixedSize()
    }

    private var tone: Color {
        switch outcome {
        case .approved, .done: .green
        case .denied: .red
        case .answered, .acknowledged, .resolvedByClaude, .answeredInSession: .blue
        case .timedOut: .orange
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
                OutcomePill(outcome: entry.outcome)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Session", entry.cwd.map { "\(entry.session) · \($0)" } ?? entry.session)
                row("Asked", HistoryEntry.timeText(entry.received))
                row("Ended", HistoryEntry.timeText(entry.ended))
                if let command = entry.command {
                    row("Command", command, monospaced: true)
                }
                if let detail = entry.detail, !detail.isEmpty {
                    row(detailLabel, detail)
                }
                if let answers = entry.answers, !answers.isEmpty {
                    row("Answers", answers.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: "\n"))
                }
                if let grant = entry.grant {
                    row("Allowed", "\(grant.scope.value), \(grant.duration == .always ? "always" : "for 1 hour")")
                }
                // Claude hears about a needs item only when it waited for it, so the
                // row shows the user's note instead.
                if entry.kind == "needs" {
                    if let note = entry.note, !note.isEmpty { row("Note", note) }
                } else {
                    row("Claude was told", toldClaude)
                }
            }
            if entry.missed, let blocked = entry.blocked, !blocked.grantScopes.isEmpty {
                HStack {
                    Menu("Allow next time…") {
                        ForEach(blocked.grantScopes, id: \.self) { scope in
                            Section(scopeTitle(scope)) {
                                Button("For 1 hour") { model.allow(scope, .hour, for: blocked) }
                                Button("Always") { model.allow(scope, .always, for: blocked) }
                            }
                        }
                    }
                    .fixedSize()
                    Text("In \(URL(fileURLWithPath: blocked.projectRoot).lastPathComponent), without asking.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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

    /// The status Claude got, with the note that came with it.
    private var toldClaude: String {
        if let note = entry.note, !note.isEmpty {
            return "\(entry.outcome.label): \(note)"
        }
        switch entry.outcome {
        case .callerGone: return "Nothing: the caller had stopped waiting."
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

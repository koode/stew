import SwiftUI
import StewCore

/// One finished request in a list, mail style: the title, the session and when it
/// ended, then its outcome and risk. A missed request the user has not seen yet has a
/// dot and a bolder title, like an unread message. Used by the History pane and the
/// menu bar popover.
struct HistoryRow: View {
    let entry: HistoryEntry
    var unseen = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(unseen ? Brand.paprika : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(!unseen)
                .accessibilityLabel("Not seen yet")
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.summary)
                    .font(.system(size: 13, weight: unseen ? .bold : .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.summary)
                HStack(spacing: 0) {
                    Text(entry.session).lineLimit(1).truncationMode(.tail)
                    Text(" · \(SettingsDate.text(entry.ended))").fixedSize()
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(entry.cwd ?? entry.session)
                HStack(spacing: 5) {
                    OutcomePill(entry: entry)
                    if let severity = entry.severity { SeverityPill(severity: severity) }
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The background of a list row: tinted while selected, stronger while the list has
/// the keyboard, as in Mail.
struct ListRowSelection: View {
    let selected: Bool
    let focused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? (focused ? Brand.paprika.opacity(0.16) : Color.primary.opacity(0.07)) : Color.clear)
    }
}

/// The one form of the history filter: every request, or only the missed ones.
struct HistoryFilterPicker: View {
    @Binding var missedOnly: Bool

    var body: some View {
        Picker("Show", selection: $missedOnly) {
            Text("All").tag(false)
            Text("Missed").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// One form for every outcome: a tinted capsule, the same size in every row. A late
/// answer shows as its own outcome, such as "Approved late", in that outcome's tone.
struct OutcomePill: View {
    let entry: HistoryEntry

    var body: some View {
        StatusPill(text: entry.outcomeLabel, tone: entry.shownOutcome.tone)
    }
}

extension HistoryEntry {
    /// One date form for History, Settings and the menu bar, such as "Nov 12, 17:15".
    static func timeText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The outcome History shows: a late answer wins over the timeout.
    var shownOutcome: Outcome { late?.outcome ?? outcome }
}

extension HistoryEntry.Outcome {
    var tone: Color {
        switch self {
        case .approved, .done: .green
        case .denied: .red
        case .answered, .acknowledged, .resolvedByClaude, .answeredInSession: .blue
        case .movedOn: .secondary
        case .timedOut, .later: .orange
        case .dismissed, .callerGone: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .approved, .done, .answered, .acknowledged, .resolvedByClaude, .answeredInSession: "checkmark"
        case .denied: "xmark"
        case .timedOut, .later: "clock"
        case .dismissed, .callerGone, .movedOn: "minus"
        }
    }
}

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
                .foregroundStyle(Ink.secondary)
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
            .fill(selected ? (focused ? Brand.paprika.opacity(Surface.selectedAlpha) : Color.primary.opacity(Surface.neutralSelectedAlpha)) : Color.clear)
    }
}

/// The one form of the history filter, in the popover and in History: every request,
/// or only the missed ones, with how many are missed. A capsule whose selected half is
/// a capsule of Liquid Glass that slides between the two; before macOS 26 the selected
/// half is a plain raised capsule. VoiceOver and the keyboard see a segmented picker.
struct HistoryFilterPicker: View {
    @Binding var missedOnly: Bool
    /// The requests the Missed filter shows; none shows no number.
    var missedCount = 0
    /// Draws the glass when the system has it. Off for the plain look, also in
    /// snapshots that cannot draw glass.
    var glass = PanelBackground.glassAvailable
    @Namespace private var selectionSpace

    var body: some View {
        HStack(spacing: 0) {
            segment("All", shows: false, count: 0)
            segment("Missed", shows: true, count: missedCount)
        }
        // The selected half sits behind both labels and takes the frame of the selected
        // one, so it slides when the selection changes and never covers a label.
        .background {
            selectionCapsule.matchedGeometryEffect(id: missedOnly, in: selectionSpace, isSource: false)
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .fixedSize()
        .accessibilityRepresentation {
            Picker("Show", selection: $missedOnly) {
                Text("All").tag(false)
                Text(missedCount > 0 ? "Missed, \(missedCount)" : "Missed").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ title: String, shows missed: Bool, count: Int) -> some View {
        let selected = missedOnly == missed
        return Button {
            withAnimation(.snappy(duration: 0.25)) { missedOnly = missed }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Ink.secondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Tone.paprika.color : Ink.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .contentShape(Capsule())
            .matchedGeometryEffect(id: missed, in: selectionSpace)
        }
        .buttonStyle(.plain)
    }

    /// The selected half.
    private var selectionCapsule: some View {
        GlassCapsule(glass: glass)
    }
}

/// A raised capsule: glass over a faint fill where the system has glass, so it still
/// reads where the glass has little behind it to bend, and a plain raised capsule before
/// macOS 26. The selected half of the history filter, and the popover header's buttons.
struct GlassCapsule: View {
    var glass = PanelBackground.glassAvailable

    var body: some View {
        let shape = Capsule()
        if glass, #available(macOS 26, *) {
            shape
                .fill(Color.primary.opacity(0.06))
                .background { Color.clear.glassEffect(.regular, in: shape) }
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        } else {
            shape
                .fill(Color(nsColor: .controlColor))
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

/// Above the list of requests, in the popover and in Settings alike: the title, the
/// All/Missed filter and Clear. Clear asks in the row itself, not in a dialog, so the
/// popover never opens a window over the user's work.
struct HistoryListHeader: View {
    @ObservedObject var model: HistoryModel
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            if confirming {
                Text(History.clearQuestion(count: model.entries.count))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Cancel") { confirming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Clear", role: .destructive) {
                    confirming = false
                    model.clear()
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
            } else {
                SectionLabel(text: "Requests")
                Spacer(minLength: 4)
                HistoryFilterPicker(missedOnly: $model.missedOnly, missedCount: model.missedCount)
                Button {
                    confirming = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Ink.secondary)
                .disabled(model.entries.isEmpty)
                .help("Clear history")
                .accessibilityLabel("Clear history")
            }
        }
        .controlSize(.small)
        .frame(height: 24)
        .onChange(of: model.entries.isEmpty) { _, empty in if empty { confirming = false } }
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
        case .approved, .done: Tone.green.color
        case .denied: Tone.red.color
        case .answered, .acknowledged, .resolvedByClaude, .answeredInSession: Tone.blue.color
        case .movedOn: Ink.secondary
        case .timedOut, .later: Tone.orange.color
        case .dismissed, .callerGone: Ink.secondary
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

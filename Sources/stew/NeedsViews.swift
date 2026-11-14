import AppKit
import SwiftUI
import StewCore

/// One look for needs items, in the panel header and the menu bar.
enum NeedsStyle {
    static let symbol = "hand.point.up.left.fill"
    static let tint = Color.teal
}

/// What Claude needs the user to do: the steps, commands to copy, links to open, the
/// other answers Claude offered, and Done or Not now. No time limit, so no clock.
struct NeedsBody: View {
    let needs: NeedsRequest
    @ObservedObject var coordinator: Coordinator
    var interactive: Bool

    var body: some View {
        let keymap = coordinator.keymap
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Claude needs you to")
                Text(needs.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(needs.title)
            }
            if let why = needs.why, !why.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Why")
                    LongText(text: why, maxLines: 6)
                }
            }
            if !needs.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Steps")
                    StepList(steps: needs.steps)
                }
            }
            if !needs.commands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: needs.commands.count == 1 ? "Command" : "Commands")
                    ForEach(Array(needs.commands.enumerated()), id: \.offset) { _, command in
                        NeedsCommandRow(command: command)
                    }
                }
            }
            if !needs.links.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: needs.links.count == 1 ? "Link" : "Links")
                    ForEach(Array(needs.links.enumerated()), id: \.offset) { _, link in
                        LinkRow(link: link)
                    }
                }
            }
            if !needs.answers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: needs.answers.count == 1 ? "Other answer" : "Other answers")
                    ForEach(Array(needs.answers.prefix(NeedsRequest.maxAnswers).enumerated()), id: \.offset) { index, answer in
                        OptionRow(
                            option: QuestionOption(label: answer, description: ""),
                            shortcut: keymap.options[index],
                            selected: false,
                            multiSelect: false
                        ) {
                            coordinator.choose(option: index)
                        }
                    }
                }
            }
            if coordinator.textMode {
                ReplyEditor(
                    coordinator: coordinator,
                    placeholder: "Note for Claude, sent with your answer",
                    hint: noteHint(keymap),
                    interactive: interactive
                )
            }
            // A long Done label gets a row of its own, still at the bottom right.
            if coordinator.showsButtons {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        secondaryButtons(keymap)
                        doneButton(keymap)
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 8) { secondaryButtons(keymap) }
                        doneButton(keymap)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func secondaryButtons(_ keymap: Keymap) -> some View {
        ActionButton(title: "Decline", shortcut: keymap[.deny]) { coordinator.perform(.deny) }
        ActionButton(title: "Note", shortcut: keymap[.other]) { coordinator.perform(.other) }
        Spacer(minLength: 8)
        ActionButton(title: "Not now", shortcut: keymap[.dismiss]) { coordinator.perform(.dismiss) }
    }

    private func doneButton(_ keymap: Keymap) -> some View {
        ActionButton(title: needs.doneTitle, shortcut: keymap[.approve], prominent: true) { coordinator.perform(.approve) }
            .help(needs.doneTitle)
    }

    /// Which keys send the note: Done's, each other answer's, and Decline's.
    private func noteHint(_ keymap: Keymap) -> Text {
        let approve = keymap[.approve].text
        let deny = keymap[.deny].text
        guard needs.hasCustomAnswers else {
            return Text("\(approve) marks it done and \(deny) declines, with this note. Esc leaves the field.")
        }
        guard let lastIndex = needs.answers.indices.last else {
            return Text("\(approve) answers \u{201C}\(needs.doneTitle)\u{201D} and \(deny) declines, with this note. Esc leaves the field.")
        }
        let answerKeys = lastIndex == 0
            ? keymap.options[0].text
            : Text("\(keymap.options[0].text) to \(keymap.options[lastIndex].text)")
        return Text("\(approve) answers \u{201C}\(needs.doneTitle)\u{201D}, \(answerKeys) the other answers, and \(deny) declines, with this note. Esc leaves the field.")
    }
}

/// Numbered steps. The numbers line up on the right, so the text of every step starts
/// at the same x.
struct StepList: View {
    let steps: [String]

    var body: some View {
        let numberWidth: CGFloat = steps.count >= 10 ? 22 : 14
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: numberWidth, alignment: .trailing)
                    Text(step)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A command box (secrets masked, with Show secrets) and a button that copies the
/// command as given.
struct NeedsCommandRow: View {
    let command: NeedsCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = command.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 6) {
                CommandBox(command: command.command)
                CopyButton(text: command.command)
            }
        }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Self.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy the command")
    }

    /// A command with a secret is marked concealed, so clipboard managers that honor
    /// the convention do not keep it.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if CommandText.hasSecrets(text) {
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }
}

/// A link that opens in the default browser.
struct LinkRow: View {
    let link: NeedsLink

    var body: some View {
        Button {
            guard NeedsRequest.isWebURL(link.url), let url = URL(string: link.url) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .medium))
                Text(link.displayText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(link.url)
    }
}

import AppKit
import SwiftUI
import StewCore

/// `stew input`: a question with one field. Like the note field, the field takes focus
/// only when the user clicks it or presses the Note key; until then it shows what it
/// holds, and the panel never takes the keyboard.
struct InputBody: View {
    let input: InputRequest
    @ObservedObject var item: Item
    @ObservedObject var coordinator: Coordinator
    var interactive: Bool

    var body: some View {
        let keymap = coordinator.keymap
        let check = input.check(item.inputText)
        VStack(alignment: .leading, spacing: 12) {
            LongText(text: input.question, size: 15, weight: .semibold, maxLines: 5)
            if let why = input.why, !why.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Why")
                    LongText(text: why, maxLines: 6)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if coordinator.textMode {
                    InputEditor(input: input, item: item, coordinator: coordinator, interactive: interactive)
                } else {
                    InputPreview(input: input, text: item.inputText, shortcut: keymap[.other]) {
                        coordinator.setTextMode(true)
                    }
                }
                hint(check)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if item.request.offersEnterLater, item.lateEntryID == nil {
                    ActionButton(title: "I'll enter it later", shortcut: keymap[.enterLater]) { coordinator.perform(.enterLater) }
                }
                if input.secret, item.timeLimit != nil {
                    ActionButton(title: "Give me 5 min", shortcut: keymap[.enterSoon]) { coordinator.perform(.enterSoon) }
                }
                Spacer()
                ActionButton(title: "Send", shortcut: keymap[.submit], prominent: true) { coordinator.perform(.submit) }
                    .disabled(!check.isValid)
                    .opacity(check.isValid ? 1 : 0.45)
                    .help(check.isValid ? "Send this answer to Claude" : "Type an answer in the expected format first")
            }
        }
    }

    /// One muted line under the field: how to type and send, or why it cannot be sent.
    @ViewBuilder
    private func hint(_ check: InputRequest.Check) -> some View {
        let keymap = coordinator.keymap
        if check == .mismatch, let expected = input.expectedText {
            (Text(InputRequest.mismatchMessage + " Expected: ")
                + Text(expected).font(.system(size: 11, design: input.expectsRawPattern ? .monospaced : .default)))
                .foregroundStyle(.orange)
        } else if coordinator.textMode {
            let returnText = input.multiline ? "Return adds a line. " : ""
            Text("\(returnText)\(keymap[.submit].text) sends. Esc leaves the field.")
                .foregroundStyle(.secondary)
        } else {
            Text("Click the field or press \(keymap[.other].text) to type. \(keymap[.submit].text) sends.")
                .foregroundStyle(.secondary)
        }
    }
}

extension InputRequest.Check {
    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

/// Sizes shared by the field and its unfocused look, so focusing it never moves the panel.
private enum InputFieldMetrics {
    static let singleLineHeight: CGFloat = 18
    static let multilineHeight: CGFloat = 64
    static let padding: CGFloat = 7

    static func height(_ input: InputRequest) -> CGFloat {
        input.multiline ? multilineHeight : singleLineHeight
    }
}

/// The field before it has focus: what it holds (dots for a secret), and the key that
/// focuses it. A click focuses it too.
struct InputPreview: View {
    let input: InputRequest
    let text: String
    let shortcut: Shortcut
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: input.multiline ? .top : .center, spacing: 8) {
                Group {
                    if text.isEmpty {
                        Text(input.placeholder ?? "Type your answer").foregroundStyle(.tertiary)
                    } else if input.secret {
                        // A fixed count, so the dots never tell how long the secret is.
                        Text(String(repeating: "•", count: 8))
                    } else {
                        Text(text)
                    }
                }
                .font(.system(size: 13))
                .lineLimit(input.multiline ? 3 : 1)
                .truncationMode(.tail)
                .padding(.leading, input.multiline ? 5 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: input.multiline ? .topLeading : .leading)
                Keycap(shortcut: shortcut)
                    .foregroundStyle(.secondary)
            }
            .frame(height: InputFieldMetrics.height(input))
            .padding(InputFieldMetrics.padding)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to type")
    }
}

/// The focused field. Plain Return never sends: in one line it does nothing, with
/// --multiline it adds a line. The submit key (⌘↩) sends and Esc leaves the field,
/// as in the note field.
struct InputEditor: View {
    let input: InputRequest
    @ObservedObject var item: Item
    @ObservedObject var coordinator: Coordinator
    var interactive: Bool
    @FocusState private var focused: Bool

    var body: some View {
        field
            .font(.system(size: 13))
            .focused($focused)
            .onKeyPress(.escape) {
                coordinator.setTextMode(false)
                return .handled
            }
            .frame(height: InputFieldMetrics.height(input))
            .padding(InputFieldMetrics.padding)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6)))
            .onAppear { if interactive { focused = true } }
    }

    private var placeholder: Text { Text(input.placeholder ?? "Type your answer") }

    @ViewBuilder private var field: some View {
        if input.secret {
            SecureField("", text: $item.inputText, prompt: placeholder)
                .textFieldStyle(.plain)
                .onSubmit {}
        } else if input.multiline {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $item.inputText)
                    .scrollContentBackground(.hidden)
                if item.inputText.isEmpty {
                    placeholder
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
        } else {
            TextField("", text: $item.inputText, prompt: placeholder)
                .textFieldStyle(.plain)
                .onSubmit {}
        }
    }
}

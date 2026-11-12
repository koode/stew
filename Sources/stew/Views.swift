import AppKit
import SwiftUI
import StewCore

struct RootView: View {
    @ObservedObject var coordinator: Coordinator
    /// False in snapshots, where there is no live panel to focus.
    var interactive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = coordinator.current {
                ItemCard(item: item, coordinator: coordinator, interactive: interactive)
                    .padding(16)
            }
            if coordinator.items.count > 1 {
                Divider()
                WaitingList(items: Array(coordinator.items.dropFirst()), dismissAll: coordinator.keymap[.dismissAll]) {
                    coordinator.perform(.dismissAll)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            if let warning = coordinator.configError ?? hotkeyWarning {
                Divider()
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }

    private var hotkeyWarning: String? {
        coordinator.hotkeyFailures.isEmpty ? nil : "Taken by another app: \(coordinator.hotkeyFailures.joined(separator: " ")). Click instead, or remap in config.json."
    }

    private var width: CGFloat {
        if coordinator.current?.blocked != nil { return 560 }
        guard case .question = coordinator.current?.request.prompt,
              let flow = coordinator.current?.flow,
              flow.current.options.contains(where: { $0.preview != nil }) else { return 520 }
        return 720
    }
}

struct ItemCard: View {
    @ObservedObject var item: Item
    @ObservedObject var coordinator: Coordinator
    var interactive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(item: item, coordinator: coordinator)
            switch item.request.prompt {
            case .permission(let permission):
                PermissionBody(permission: permission, item: item, coordinator: coordinator, interactive: interactive)
            case .notify(let notify):
                NotifyBody(notify: notify, coordinator: coordinator)
            case .question:
                QuestionBody(item: item, coordinator: coordinator, interactive: interactive)
            }
        }
    }
}

private struct KindStyle {
    let title: String
    let symbol: String
    let tint: Color

    init(_ prompt: Prompt) {
        switch prompt {
        case .permission:
            self.init(title: "Permission request", symbol: "hand.raised.fill", tint: .orange)
        case .question:
            self.init(title: "Question", symbol: "questionmark.bubble.fill", tint: .purple)
        case .notify(let notify):
            switch notify.level {
            case .info: self.init(title: "Notification", symbol: "bell.fill", tint: .blue)
            case .success: self.init(title: "Done", symbol: "checkmark", tint: .green)
            case .warning: self.init(title: "Warning", symbol: "exclamationmark.triangle.fill", tint: .orange)
            case .error: self.init(title: "Error", symbol: "xmark.octagon.fill", tint: .red)
            }
        }
    }

    init(title: String, symbol: String, tint: Color) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }
}

struct Header: View {
    @ObservedObject var item: Item
    @ObservedObject var coordinator: Coordinator

    var body: some View {
        let style = KindStyle(item.request.prompt)
        let session = item.request.session
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: style.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(([style.title] + [session.cwd, session.shortID].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if coordinator.items.count > 1 {
                Text("1 of \(coordinator.items.count)")
                    .fixedSize()
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help("Older requests show first; the rest wait below")
            }
            if item.timeLimit != nil {
                TimeLimit(item: item, coordinator: coordinator)
            }
            Button { coordinator.perform(.dismiss) } label: {
                HStack(spacing: 5) {
                    Keycap(shortcut: coordinator.keymap[.dismiss])
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Dismiss without answering")
        }
    }
}

/// Time left to answer, and the "more time" button. Paused while typing a note.
struct TimeLimit: View {
    @ObservedObject var item: Item
    @ObservedObject var coordinator: Coordinator

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let deadline = item.deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = deadline.timeIntervalSince(context.date)
                        Text(Self.format(remaining))
                            .foregroundStyle(remaining <= 30 ? Color.orange : Color.secondary)
                    }
                } else if let remaining = item.pausedRemaining {
                    Text("Paused \(Self.format(remaining))").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .fixedSize()
            .help("When this runs out, Claude is told you did not respond in time")
            Button { coordinator.perform(.extend) } label: {
                HStack(spacing: 4) {
                    Text(Self.extendLabel(coordinator.config.extendBy)).font(.system(size: 11, weight: .medium))
                    Keycap(shortcut: coordinator.keymap[.extend])
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help("More time")
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func extendLabel(_ seconds: Double) -> String {
        seconds >= 60 ? "+\(Int(seconds / 60)) min" : "+\(Int(seconds)) s"
    }
}

struct Keycap: View {
    let shortcut: Shortcut
    var onTint = false

    var body: some View {
        Text(shortcut.description)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(onTint ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .fixedSize()
    }
}

struct ActionButton: View {
    let title: String
    let shortcut: Shortcut
    var prominent = false
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 13, weight: prominent ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
                Keycap(shortcut: shortcut, onTint: prominent)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prominent ? tint : Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

struct CommandBox: View {
    let command: String
    @State private var revealed = false

    var body: some View {
        let hasSecrets = CommandText.hasSecrets(command)
        let shown = hasSecrets && !revealed ? CommandText.masked(command) : command
        VStack(alignment: .trailing, spacing: 4) {
            box(shown)
            if hasSecrets {
                Button(revealed ? "Hide secrets" : "Show secrets") { revealed.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func box(_ command: String) -> some View {
        let text = Text(command)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        return Group {
            if command.split(separator: "\n", omittingEmptySubsequences: false).count > 12 || command.count > 900 {
                ScrollView { text }.frame(height: 220)
            } else {
                text.fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct RiskBanner: View {
    let state: RiskState

    var body: some View {
        switch state {
        case .off:
            EmptyView()
        case .checking:
            banner(tint: .secondary, symbol: nil, title: "Checking against your auto mode rules…", detail: nil)
        case .failed(let reason):
            banner(tint: .secondary, symbol: "questionmark.diamond", title: "Risk check unavailable", detail: reason)
        case .blocked(let blocked):
            banner(
                tint: blocked.hardDeny ? .red : .orange,
                symbol: blocked.hardDeny ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                title: ["Auto mode blocked this", blocked.category].compactMap { $0 }.joined(separator: " · "),
                detail: blocked.hardDeny
                    ? "This rule blocks even when you ask. Approving lets Claude retry this exact call once."
                    : "Approving lets Claude retry this exact call once."
            )
        case .done(let assessment):
            switch assessment.verdict {
            case .allow:
                banner(tint: .green, symbol: "checkmark", title: title("Auto mode would allow this", assessment), detail: assessment.summary)
            case .softDeny:
                banner(tint: .orange, symbol: "exclamationmark.triangle.fill", title: title("Auto mode would block this", assessment), detail: assessment.summary)
            case .hardDeny:
                banner(tint: .red, symbol: "xmark.octagon.fill", title: title("Auto mode never allows this", assessment), detail: assessment.summary)
            }
        }
    }

    private func title(_ base: String, _ assessment: RiskAssessment) -> String {
        guard let rule = assessment.ruleName else { return base }
        return "\(base) · \(rule)"
    }

    private func banner(tint: Color, symbol: String?, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(tint)
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct ReplyEditor: View {
    @ObservedObject var coordinator: Coordinator
    let placeholder: String
    let hint: String
    var interactive: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $coordinator.draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .onKeyPress(.escape) {
                        coordinator.setTextMode(false)
                        return .handled
                    }
                if coordinator.draft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 64)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6)))
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .onAppear { if interactive { focused = true } }
    }
}

struct PermissionBody: View {
    let permission: PermissionRequest
    @ObservedObject var item: Item
    @ObservedObject var coordinator: Coordinator
    var interactive: Bool

    var body: some View {
        let keymap = coordinator.keymap
        let approveShortcut = item.isHardDeny ? keymap[.approve].adding(keymap.hardDenyExtra) : keymap[.approve]
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Claude wants to")
                Text(permission.action)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            RiskBanner(state: item.risk)
            if let command = permission.command, !command.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Command")
                    CommandBox(command: command)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: item.blocked == nil ? "Why" : "Claude's last message")
                Text(permission.reason)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if coordinator.textMode {
                ReplyEditor(
                    coordinator: coordinator,
                    placeholder: "Note for Claude, sent with your answer",
                    hint: "\(approveShortcut) approves and \(keymap[.deny]) denies with this note. Esc leaves the field.",
                    interactive: interactive
                )
            }
            if coordinator.grantMode, let blocked = item.blocked {
                GrantPicker(blocked: blocked, coordinator: coordinator)
            } else {
            HStack(spacing: 8) {
                ActionButton(title: "Deny", shortcut: keymap[.deny]) { coordinator.perform(.deny) }
                ActionButton(title: "Note", shortcut: keymap[.other]) { coordinator.perform(.other) }
                if let blocked = item.blocked, !blocked.grantScopes.isEmpty {
                    ActionButton(title: "Allow more…", shortcut: keymap[.grant]) { coordinator.perform(.grant) }
                }
                Spacer()
                ActionButton(
                    title: item.isHardDeny ? "Approve anyway" : "Approve",
                    shortcut: approveShortcut,
                    prominent: true,
                    tint: item.isHardDeny ? .red : .accentColor
                ) { coordinator.perform(.approve) }
            }
            }
        }
    }
}

/// "Allow more…": pick what to allow without asking, then for an hour or for good.
struct GrantPicker: View {
    let blocked: BlockedCall
    @ObservedObject var coordinator: Coordinator

    var body: some View {
        let keymap = coordinator.keymap
        let scopes = blocked.grantScopes
        let selected = scopes.indices.contains(coordinator.grantSelection) ? scopes[coordinator.grantSelection] : scopes.first
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Allow without asking")
                    Text("In \(URL(fileURLWithPath: blocked.projectRoot).lastPathComponent). This call runs too.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage approvals…") { coordinator.openApprovals() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(Array(scopes.enumerated()), id: \.offset) { index, scope in
                    ScopeRow(scope: scope, shortcut: keymap.options[index], selected: index == coordinator.grantSelection) {
                        coordinator.choose(option: index)
                    }
                }
            }
            if let selected {
                Text(alwaysHint(selected))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ActionButton(title: "Back", shortcut: keymap[.grant]) { coordinator.perform(.grant) }
                Spacer()
                ActionButton(title: "Always", shortcut: keymap[.approve].adding(keymap.hardDenyExtra)) { coordinator.perform(.grantAlways) }
                ActionButton(title: "For 1 hour", shortcut: keymap[.approve], prominent: true) { coordinator.perform(.approve) }
            }
        }
    }

    private func alwaysHint(_ scope: GrantChoice.Scope) -> String {
        switch scope.kind {
        case .exact, .pattern:
            return "Always adds Bash(\(scope.value)) to this project's .claude/settings.local.json. An hour keeps it in stew."
        case .category:
            return "Kept in stew for this project. Revoke it under Manage approvals."
        }
    }
}

struct ScopeRow: View {
    let scope: GrantChoice.Scope
    let shortcut: Shortcut
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Keycap(shortcut: shortcut)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    switch scope.kind {
                    case .exact, .pattern:
                        Text(scope.value)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(scope.kind == .exact ? "This command" : "Commands that start like this")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    case .category:
                        Text(scope.value).font(.system(size: 13, weight: .medium))
                        Text("Anything auto mode blocks as this, any tool")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NotifyBody: View {
    let notify: NotifyRequest
    @ObservedObject var coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(notify.title)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let body = notify.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                ActionButton(title: "OK", shortcut: coordinator.keymap[.approve], prominent: true) { coordinator.perform(.approve) }
            }
        }
    }
}

struct QuestionBody: View {
    @ObservedObject var item: Item
    @ObservedObject var coordinator: Coordinator
    var interactive: Bool

    var body: some View {
        if let flow = item.flow {
            let question = flow.current
            let keymap = coordinator.keymap
            let hasPreview = question.options.contains { $0.preview != nil }
            VStack(alignment: .leading, spacing: 12) {
                if flow.questions.count > 1 {
                    QuestionTabs(flow: flow) { coordinator.goToQuestion($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.question)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if question.multiSelect {
                        Text("Choose any, then \(keymap[.submit].description) to confirm.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 6) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            OptionRow(
                                option: option,
                                shortcut: keymap.options[index],
                                selected: flow.selections[flow.index].contains(index),
                                multiSelect: question.multiSelect
                            ) {
                                coordinator.choose(option: index)
                            }
                            .onHover { inside in
                                if inside { item.hoveredOption = index } else if item.hoveredOption == index { item.hoveredOption = nil }
                            }
                        }
                        OtherRow(shortcut: keymap[.other], text: flow.otherText[flow.index], active: coordinator.textMode) {
                            coordinator.perform(.other)
                        }
                    }
                    .frame(width: hasPreview ? 300 : nil)
                    if hasPreview {
                        PreviewBox(text: previewText(flow))
                    }
                }
                if coordinator.textMode {
                    ReplyEditor(
                        coordinator: coordinator,
                        placeholder: "Type your answer",
                        hint: "\(keymap[.submit]) sends. Esc leaves the field.",
                        interactive: interactive
                    )
                }
                if flow.questions.count > 1 || question.multiSelect || coordinator.textMode {
                    HStack(spacing: 8) {
                        if flow.questions.count > 1 {
                            ActionButton(title: "Back", shortcut: keymap[.previous]) { coordinator.perform(.previous) }
                            ActionButton(title: "Next", shortcut: keymap[.next]) { coordinator.perform(.next) }
                        }
                        Spacer()
                        if question.multiSelect || coordinator.textMode {
                            ActionButton(title: flow.isLast ? "Submit" : "Confirm", shortcut: keymap[.submit], prominent: true) {
                                coordinator.perform(.submit)
                            }
                        }
                    }
                }
            }
        }
    }

    private func previewText(_ flow: QuestionFlow) -> String {
        let options = flow.current.options
        let index = item.hoveredOption ?? flow.selections[flow.index].sorted().first ?? options.firstIndex { $0.preview != nil } ?? 0
        return options.indices.contains(index) ? (options[index].preview ?? "No preview for this option.") : ""
    }
}

struct QuestionTabs: View {
    let flow: QuestionFlow
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(flow.questions.enumerated()), id: \.offset) { index, question in
                Button { select(index) } label: {
                    HStack(spacing: 4) {
                        if flow.isAnswered(index) {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        }
                        Text(question.header.isEmpty ? "Q\(index + 1)" : question.header)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(index == flow.index ? Color.white : Color.primary)
                    .background(Capsule().fill(index == flow.index ? Color.accentColor : Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct OptionRow: View {
    let option: QuestionOption
    let shortcut: Shortcut
    let selected: Bool
    let multiSelect: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Keycap(shortcut: shortcut)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .medium))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if multiSelect {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct OtherRow: View {
    let shortcut: Shortcut
    let text: String?
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Keycap(shortcut: shortcut)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other…").font(.system(size: 13, weight: .medium))
                    if let text, !text.isEmpty {
                        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active || !(text ?? "").isEmpty ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PreviewBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct WaitingList: View {
    let items: [Item]
    let dismissAll: Shortcut
    let dismissAllAction: () -> Void

    init(items: [Item], dismissAll: Shortcut, action: @escaping () -> Void) {
        self.items = items
        self.dismissAll = dismissAll
        dismissAllAction = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SectionLabel(text: "\(items.count) more waiting")
                Spacer()
                Button(action: dismissAllAction) {
                    HStack(spacing: 5) {
                        Text("Dismiss all").font(.system(size: 11))
                        Keycap(shortcut: dismissAll)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ForEach(items.prefix(3)) { item in
                let style = KindStyle(item.request.prompt)
                HStack(spacing: 6) {
                    Image(systemName: style.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(style.tint)
                        .frame(width: 14)
                    Text(item.request.session.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(summary(item.request.prompt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if items.count > 3 {
                Text("and \(items.count - 3) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ prompt: Prompt) -> String {
        switch prompt {
        case .permission(let permission): permission.action
        case .notify(let notify): notify.title
        case .question(let set): set.questions.first?.question ?? ""
        }
    }
}

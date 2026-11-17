import AppKit
import SwiftUI
import StewCore

/// The brand's paprika, from the app icon and stewcli.com. Dark mode uses a lighter
/// shade, so text and outlines in it keep their contrast.
enum Brand {
    static let paprika = Color(nsColor: NSColor(name: "stew.paprika") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xF2 / 255, green: 0x6A / 255, blue: 0x42 / 255, alpha: 1)
            : NSColor(srgbRed: 0xE4 / 255, green: 0x57 / 255, blue: 0x2E / 255, alpha: 1)
    })
}

/// A tab of a tab bar: its name and symbol.
protocol PaneTab: Hashable, Identifiable {
    var title: String { get }
    var symbol: String { get }
}

extension SettingsTab: PaneTab {
    /// The order of the tab bar.
    static let order: [SettingsTab] = [.general, .keys, .agents, .phone, .account, .approvals, .history]

    var title: String {
        switch self {
        case .general: "General"
        case .keys: "Keys"
        case .agents: "Agents"
        case .phone: "iPhone"
        case .account: "Account"
        case .approvals: "Approvals"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keys: "keyboard"
        case .agents: "terminal"
        case .phone: "iphone"
        case .account: "person.crop.circle"
        case .approvals: "lock.open"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// One line under the pane's title.
    var subtitle: String {
        switch self {
        case .general: "The menu bar, how long the panel waits for you, where it appears and how it sounds."
        case .keys: "Shortcuts that answer the panel from any app."
        case .agents: "How Claude Code and Codex reach stew: blocked calls, approvals, questions and needs."
        case .phone: "Answer requests on your iPhone while you are away from the Mac."
        case .account: "Only the iPhone relay needs a plan. Everything else in stew is free."
        case .approvals: "Calls that auto mode blocks but these approvals let through without asking."
        case .history: "Every finished request, with what the agent was told."
        }
    }
}

/// The toolbar of a macOS Settings window: one symbol and name per pane. Drawn in
/// SwiftUI rather than an NSToolbar, so it also renders in offscreen snapshots.
struct SettingsTabBar<Tab: PaneTab>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    /// Tabs whose work is done get a check at the corner of their symbol.
    var isDone: (Tab) -> Bool = { _ in false }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(selected ? Brand.paprika : Ink.secondary)
                            .frame(height: 22)
                            .overlay(alignment: .topTrailing) {
                                if isDone(tab) { DoneBadge().offset(x: 9, y: -3) }
                            }
                        Text(tab.title)
                            .font(.system(size: 11, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Color.primary : Ink.secondary)
                    }
                    .frame(width: 78, height: 48)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.primary.opacity(0.07) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The selected tab already shows where you are; the focus ring would stay on
                // the first tab after the window opens, whatever is selected.
                .focusEffectDisabled()
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }
}

/// The one form of "done" on a tab: a white check on a filled green disc.
struct DoneBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(StewCore.Tone.green.color))
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .accessibilityLabel("Done")
    }
}

/// The brand tile at the top of each pane: the pane's symbol in white on paprika.
struct BrandTile: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Brand.paprika.gradient)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            )
    }
}

/// A pane: its header (tile, title, one line about it, an optional control on the
/// right) above the pane's content. Header and content share one column on the left of
/// the window, so in a wide window they still start at the same x; a full-width pane,
/// such as History's list beside its preview, takes the whole window instead.
struct SettingsPane<Accessory: View, Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    var fullWidth = false
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(symbol: String, title: String, subtitle: String, fullWidth: Bool = false, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.fullWidth = fullWidth
        self.accessory = accessory()
        self.content = content()
    }

    init(tab: SettingsTab, subtitle: String? = nil, fullWidth: Bool = false, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.init(symbol: tab.symbol, title: tab.title, subtitle: subtitle ?? tab.subtitle, fullWidth: fullWidth, accessory: accessory, content: content)
    }

    var body: some View {
        column
            .frame(maxWidth: fullWidth ? .infinity : SettingsMetrics.columnWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                BrandTile(symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, SettingsMetrics.inset)
            .padding(.top, 18)
            .padding(.bottom, 6)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

extension SettingsPane where Accessory == EmptyView {
    init(tab: SettingsTab, subtitle: String? = nil, fullWidth: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(tab: tab, subtitle: subtitle, fullWidth: fullWidth, accessory: { EmptyView() }, content: content)
    }

    init(symbol: String, title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

enum SettingsMetrics {
    /// The left edge of headers, cards and tables, the same as a grouped Form's sections.
    static let inset: CGFloat = 28
    /// The widest a pane's column gets: the width the window opens at, so a wider window
    /// adds room on the right instead of moving the content away from its header.
    static let columnWidth: CGFloat = 760
}

/// A form of settings: the grouped macOS form on the window's background, so the
/// header and the sections read as one surface.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

/// A form field: the label is the name only; the hint sits under the input.
struct SettingRow<Content: View>: View {
    let hint: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            if let hint { Hint(hint) }
        }
    }
}

/// The one form of a hint: smaller, muted text under the thing it explains.
struct Hint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The one form of a status: a tinted capsule with a short word or two.
struct StatusPill: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.opacity(Tone.fillAlpha)))
            .fixedSize()
    }
}

/// The one form of a message about something that happened: an error, or a success.
/// The whole surface is tinted; there is no stripe on the side.
struct Notice: View {
    enum Tone {
        case error, success

        var color: Color { self == .error ? StewCore.Tone.orange.color : StewCore.Tone.green.color }
        var symbol: String { self == .error ? "exclamationmark.triangle.fill" : "checkmark" }
    }

    let tone: Tone
    let text: String
    /// A button after the text: its label and what it does.
    let action: (label: String, perform: () -> Void)?

    init(_ tone: Tone, _ text: String, action: (label: String, perform: () -> Void)? = nil) {
        self.tone = tone
        self.text = text
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: tone.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tone.color)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let action {
                Button(action.label, action: action.perform)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tone.color.opacity(0.13)))
    }
}

/// The one form of an empty list: a symbol, a short title, a sentence, and the action
/// that fills it when there is one.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(height: 34)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, 6)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message, actions: { EmptyView() })
    }
}

/// The card around a table or an empty state outside a Form, matching a Form section.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The one form of a moment in Settings, such as "Nov 12, 17:15".
enum SettingsDate {
    static func text(_ date: Date) -> String {
        HistoryEntry.timeText(date)
    }
}

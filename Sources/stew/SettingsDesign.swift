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

extension SettingsTab {
    /// The order of the tab bar.
    static let order: [SettingsTab] = [.general, .keys, .claude, .phone, .approvals, .history]

    var title: String {
        switch self {
        case .general: "General"
        case .keys: "Keys"
        case .claude: "Claude Code"
        case .phone: "iPhone"
        case .approvals: "Approvals"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keys: "keyboard"
        case .claude: "terminal"
        case .phone: "iphone"
        case .approvals: "lock.open"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// One line under the pane's title.
    var subtitle: String {
        switch self {
        case .general: "The menu bar, how long the panel waits for you, where it appears and how it sounds."
        case .keys: "Shortcuts that answer the panel from any app."
        case .claude: "How Claude Code's blocked calls, questions and needs reach stew."
        case .phone: "Answer requests on your iPhone while you are away from the Mac."
        case .approvals: "Calls that auto mode blocks but these approvals let through without asking."
        case .history: "Every finished request, with what Claude was told."
        }
    }
}

/// The toolbar of a macOS Settings window: one symbol and name per pane. Drawn in
/// SwiftUI rather than an NSToolbar, so it also renders in offscreen snapshots.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.order) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(selected ? Brand.paprika : Color.secondary)
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 11, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
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
/// right) above the pane's content.
struct SettingsPane<Accessory: View, Content: View>: View {
    let tab: SettingsTab
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                BrandTile(symbol: tab.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title).font(.system(size: 17, weight: .semibold))
                    Text(subtitle ?? tab.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
    init(tab: SettingsTab, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(tab: tab, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

enum SettingsMetrics {
    /// The left edge of headers, cards and tables, the same as a grouped Form's sections.
    static let inset: CGFloat = 28
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
            .foregroundStyle(.secondary)
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
            .background(Capsule().fill(tone.opacity(0.15)))
            .fixedSize()
    }
}

/// The one form of a message about something that happened: an error, or a success.
/// The whole surface is tinted; there is no stripe on the side.
struct Notice: View {
    enum Tone {
        case error, success

        var color: Color { self == .error ? .orange : .green }
        var symbol: String { self == .error ? "exclamationmark.triangle.fill" : "checkmark" }
    }

    let tone: Tone
    let text: String

    init(_ tone: Tone, _ text: String) {
        self.tone = tone
        self.text = text
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
                .foregroundStyle(.secondary)
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

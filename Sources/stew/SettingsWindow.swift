import AppKit
import SwiftUI
import StewCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, keys, claude, approvals
    var id: String { rawValue }
}

/// Reads and writes ~/.config/stew/config.json. Every change is checked and saved at once.
final class SettingsModel: ObservableObject {
    @Published private(set) var config = StewConfig()
    @Published private(set) var keymap = try! Keymap(config: StewConfig())
    @Published private(set) var error: String?
    @Published private(set) var hookState: ClaudeSettings.HookState = .none
    @Published var tab: SettingsTab = .general
    var onSaved: (() -> Void)?

    func load() {
        let (loaded, loadError) = loadConfig()
        config = loaded
        keymap = (try? Keymap(config: loaded)) ?? keymap
        error = loadError
        hookState = ClaudeSettings.hookState(
            executable: Hooks.installedExecutable,
            in: FileManager.default.contents(atPath: Hooks.claudeSettingsPath)
        )
    }

    /// Applies a change, refusing it when the keys would clash.
    func update(_ change: (inout StewConfig) -> Void) {
        var updated = config
        change(&updated)
        do {
            let updatedKeymap = try Keymap(config: updated)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(updated)
            let folder = (Paths.config as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: Paths.config), options: .atomic)
            config = updated
            keymap = updatedKeymap
            error = nil
            onSaved?()
        } catch {
            self.error = "\(error)"
        }
    }

    func setShortcut(_ shortcut: Shortcut, for action: HotkeyAction) {
        update { $0.keys[action.rawValue] = shortcut.spec }
    }

    func setOptionShortcut(_ shortcut: Shortcut, at index: Int) {
        update { config in
            var keys = config.optionKeys
            while keys.count < 4 { keys.append(String(keys.count + 1)) }
            keys[index] = shortcut.spec
            config.optionKeys = keys
        }
    }

    func resetKeys() {
        let defaults = StewConfig()
        update { config in
            config.chord = defaults.chord
            config.keys = defaults.keys
            config.optionKeys = defaults.optionKeys
            config.hardDenyExtra = defaults.hardDenyExtra
        }
    }

    func setHooks(installed: Bool) {
        do {
            if installed { try Hooks.install() } else { try Hooks.uninstall() }
            error = nil
        } catch {
            self.error = "\(error)"
        }
        load()
    }
}

final class SettingsWindowController {
    private let model = SettingsModel()
    private let approvals = ApprovalsModel()
    private var window: NSWindow?

    init(onSaved: @escaping () -> Void) {
        model.onSaved = onSaved
    }

    func show(_ tab: SettingsTab) {
        model.load()
        approvals.reload()
        model.tab = tab
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "stew Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, approvals: approvals))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var approvals: ApprovalsModel

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $model.tab) {
                GeneralSettings(model: model).tabItem { Text("General") }.tag(SettingsTab.general)
                KeySettings(model: model).tabItem { Text("Keys") }.tag(SettingsTab.keys)
                ClaudeSettingsTab(model: model).tabItem { Text("Claude Code") }.tag(SettingsTab.claude)
                ApprovalsView(model: approvals).tabItem { Text("Approvals") }.tag(SettingsTab.approvals)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(minWidth: 680, minHeight: 460)
    }
}

/// A form field: the label is the name only; the hint sits under the input.
struct SettingRow<Content: View>: View {
    let hint: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel

    private static let limits: [(String, Double)] = [("No limit", 0), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600)]
    private static let extensions: [(String, Double)] = [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)]
    private static let delays: [(String, Double)] = [("Off", 0), ("0.25 seconds", 0.25), ("0.5 seconds", 0.5), ("1 second", 1)]
    private static let positions: [(String, String)] = [("Top right", "top-right"), ("Top center", "top-center"), ("Top left", "top-left")]
    private static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    var body: some View {
        Form {
            SettingRow(hint: "When it runs out, Claude is told you did not respond in time, so it can go another way. Applies to permission requests and questions.") {
                Picker("Time to answer", selection: binding(\.responseTimeout)) {
                    ForEach(Self.limits, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            SettingRow(hint: "Added each time you press More time. The clock also pauses while you type a note.") {
                Picker("More time", selection: binding(\.extendBy)) {
                    ForEach(Self.extensions, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            SettingRow(hint: "Keys do nothing this long after a panel appears, so a shortcut meant for another app cannot answer it.") {
                Picker("Ignore keys at first", selection: binding(\.armDelay)) {
                    ForEach(Self.delays, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            SettingRow(hint: nil) {
                Picker("Position", selection: binding(\.position)) {
                    ForEach(Self.positions, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            SettingRow(hint: "Plays when a panel appears.") {
                Picker("Sound", selection: Binding(
                    get: { model.config.sound ?? "" },
                    set: { value in model.update { $0.sound = value } }
                )) {
                    Text("None").tag("")
                    ForEach(Self.sounds, id: \.self) { Text($0).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value: Hashable>(_ keyPath: WritableKeyPath<StewConfig, Value>) -> Binding<Value> {
        Binding(get: { model.config[keyPath: keyPath] }, set: { value in model.update { $0[keyPath: keyPath] = value } })
    }
}

struct KeySettings: View {
    @ObservedObject var model: SettingsModel

    private static let actions: [(HotkeyAction, String)] = [
        (.approve, "Approve or OK"),
        (.deny, "Deny"),
        (.other, "Note or Other…"),
        (.grant, "Allow more…"),
        (.extend, "More time"),
        (.submit, "Confirm or send"),
        (.previous, "Previous question"),
        (.next, "Next question"),
        (.dismiss, "Dismiss"),
        (.dismissAll, "Dismiss all"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.actions, id: \.0) { action, name in
                    LabeledContent(name) {
                        KeyRecorder(shortcut: model.keymap[action]) { model.setShortcut($0, for: action) }
                    }
                }
                ForEach(0..<4, id: \.self) { index in
                    LabeledContent("Option \(index + 1)") {
                        KeyRecorder(shortcut: model.keymap.options[index]) { model.setOptionShortcut($0, at: index) }
                    }
                }
            } footer: {
                Text("Click a key, then press the new combination. It needs Control, Option or Command, so plain typing never answers a panel. Esc cancels.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                SettingRow(hint: "Approving a call that auto mode would never allow needs this key as well as Approve.") {
                    Picker("Extra key past a hard deny", selection: Binding(
                        get: { model.config.hardDenyExtra },
                        set: { value in model.update { $0.hardDenyExtra = value } }
                    )) {
                        Text("Shift").tag("shift")
                        Text("Option").tag("option")
                        Text("Control").tag("ctrl")
                    }
                }
                Button("Reset keys to defaults") { model.resetKeys() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press a combination. Captures with a local key monitor, so it works
/// only while the settings window has focus.
struct KeyRecorder: View {
    let shortcut: Shortcut
    let onChange: (Shortcut) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : shortcut.description)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 110)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.intersection([.command, .control, .option]).isEmpty {
                stop()
                return nil
            }
            if let recorded = Self.shortcut(from: event) {
                onChange(recorded)
            } else {
                NSSound.beep()
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func shortcut(from event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        guard !modifiers.intersection([.control, .option, .command]).isEmpty else { return nil }
        let specials: [UInt16: Key.Special] = [
            36: .return, 76: .return, 53: .escape, 48: .tab, 49: .space, 51: .delete,
            123: .left, 124: .right, 125: .down, 126: .up,
        ]
        if let special = specials[event.keyCode] {
            return Shortcut(modifiers: modifiers, key: .special(special))
        }
        guard let character = event.charactersIgnoringModifiers?.lowercased().first, !character.isWhitespace else { return nil }
        return Shortcut(modifiers: modifiers, key: .character(character))
    }
}

struct ClaudeSettingsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Hooks") {
                SettingRow(hint: "When auto mode blocks a call, stew asks you, and an approved call is retried once. Questions can come to stew too. Changes ~/.claude/settings.json; a backup is written first.") {
                    LabeledContent("Hooks") {
                        HStack {
                            switch model.hookState {
                            case .complete:
                                Text("Installed").foregroundStyle(.secondary)
                                Button("Uninstall") { model.setHooks(installed: false) }
                            case .partial:
                                Text("Needs an update").foregroundStyle(.orange)
                                Button("Update") { model.setHooks(installed: true) }
                            case .none:
                                Text("Not installed").foregroundStyle(.secondary)
                                Button("Install") { model.setHooks(installed: true) }
                            }
                        }
                    }
                }
                SettingRow(hint: "Where Claude Code's questions (AskUserQuestion) appear. Unattended means background and remote sessions; a session you are typing in keeps asking in the terminal.") {
                    Picker("Questions", selection: Binding(
                        get: { model.config.routeQuestions },
                        set: { value in model.update { $0.routeQuestions = value } }
                    )) {
                        Text("In stew for unattended sessions").tag(QuestionRouting.unattended)
                        Text("Always in stew").tag(QuestionRouting.always)
                        Text("Always in the terminal").tag(QuestionRouting.never)
                    }
                }
            }
            Section("Risk check") {
                SettingRow(hint: "For direct stew permit calls: claude -p checks the command against your auto mode rules. Runs on your Claude subscription only, never on API billing.") {
                    Toggle("Risk check", isOn: Binding(
                        get: { model.config.classifier.enabled },
                        set: { value in model.update { $0.classifier.enabled = value } }
                    ))
                }
                SettingRow(hint: "Haiku takes about 5 seconds per check. Larger models are slower and use more of your plan.") {
                    Picker("Model", selection: Binding(
                        get: { model.config.classifier.model },
                        set: { value in model.update { $0.classifier.model = value } }
                    )) {
                        Text("Haiku").tag("haiku")
                        Text("Sonnet").tag("sonnet")
                        Text("Opus").tag("opus")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

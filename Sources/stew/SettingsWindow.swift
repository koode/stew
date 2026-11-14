import AppKit
import Combine
import SwiftUI
import StewCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, keys, claude, approvals, history
    var id: String { rawValue }
    case phone
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
    private let history = HistoryModel()
    private let updater: Updater
    private let pause: PauseModel
    private var window: NSWindow?
    private var tabTitle: AnyCancellable?
    private var historyTab: AnyCancellable?
    /// True while `show` sets the tab, so the tab bar's handler leaves it alone.
    private var changingTab = false
    /// Called each time the History pane shows, which counts as seeing missed requests.
    /// Returns when History showed before, so the requests missed since keep a dot.
    var onHistoryShown: (() -> Date?)?

    init(updater: Updater, pause: PauseModel, onSaved: @escaping () -> Void) {
        self.updater = updater
        self.pause = pause
        model.onSaved = onSaved
    }

    /// "Hide menu bar icon" in the menu: the same as turning off Show in menu bar.
    func setShowInMenuBar(_ shown: Bool) {
        model.load()
        model.update { $0.menuBar = shown }
    }

    /// History's preview takes the panel's keys, or lets go of them.
    var onPreviewKeys: ((Bool) -> Void)? {
        get { history.onPreviewKeys }
        set { history.onPreviewKeys = newValue }
    }

    /// A late answer from History's preview. False when it is too late.
    var onClearHistory: (() -> Void)? {
        get { history.onClear }
        set { history.onClear = newValue }
    }

    var onLateAnswer: ((UUID, StewResponse) -> Bool)? {
        get { history.onLateAnswer }
        set { history.onLateAnswer = newValue }
    }

    func reloadHistory() {
        history.reload()
    }

    func show(_ tab: SettingsTab) {
        model.load()
        approvals.reload()
        history.reload()
        // The tab is set here rather than through the tab bar: History's opening is
        // handled once, below.
        changingTab = true
        model.tab = tab
        changingTab = false
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            // The title bar takes the window's background, so it and the tab bar below
            // read as one toolbar, as in other Settings windows.
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, approvals: approvals, history: history, updater: updater, pause: pause))
            window.center()
            self.window = window
            // Like other Settings windows, the title names the pane that is showing.
            tabTitle = model.$tab.sink { [weak window] tab in window?.title = tab.title }
            historyTab = model.$tab.sink { [weak self] tab in
                guard let self, !self.changingTab else { return }
                if tab == .history, self.window?.isVisible == true { self.historyShown() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if tab == .history { historyShown() }
    }

    /// History needs room for its list beside the panel's preview.
    static let historyWidth: CGFloat = 1040

    /// History opened: the newest request in its filter is selected, and the missed
    /// requests count as seen.
    private func historyShown() {
        history.open(missedOnly: history.missedOnly)
        history.markUnseen(since: onHistoryShown?() ?? nil)
        guard let window, window.frame.width < Self.historyWidth, let screen = window.screen else { return }
        var frame = window.frame
        let grow = Self.historyWidth - frame.width
        frame.size.width = Self.historyWidth
        frame.origin.x = max(screen.visibleFrame.minX, frame.origin.x - grow / 2)
        window.setFrame(frame.intersection(screen.visibleFrame), display: true, animate: window.isVisible)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var approvals: ApprovalsModel
    @ObservedObject var history: HistoryModel
    let updater: Updater
    var pause = PauseModel()
    var link: PhoneLink = .shared
    /// Starting state of the iPhone pane, for `stew snapshot`.
    var phoneSample = PhonePaneSample()

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $model.tab)
            Divider()
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.error {
                Notice(.error, error)
                    .padding(.horizontal, SettingsMetrics.inset)
                    .padding(.bottom, 14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.paprika)
        .frame(minWidth: 680, minHeight: 500)
    }

    @ViewBuilder
    private var pane: some View {
        switch model.tab {
        case .general: GeneralSettings(model: model, updater: updater, pause: pause)
        case .keys: KeySettings(model: model)
        case .claude: ClaudeSettingsTab(model: model)
        case .phone: PhoneSettingsTab(model: model, link: link, sample: phoneSample)
        case .approvals: ApprovalsView(model: approvals)
        case .history: HistoryView(model: history)
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var updater: Updater
    @ObservedObject var pause: PauseModel

    private static let limits: [(String, Double)] = [("No limit", 0), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600)]
    private static let extensions: [(String, Double)] = [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)]
    private static let delays: [(String, Double)] = [("Off", 0), ("0.25 seconds", 0.25), ("0.5 seconds", 0.5), ("1 second", 1)]
    private static let positions: [(String, String)] = [("Top right", "top-right"), ("Top center", "top-center"), ("Top left", "top-left")]
    /// 05:00 to 12:00, and an hour set in config.json outside them.
    private static func morningHours(including chosen: Int) -> [Int] {
        Array(Set(Array(5...12) + [chosen])).sorted()
    }

    /// An hour as the clock shows it, in the form of the end of a pause: "08:00".
    private static func hourText(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return PauseState.timeOfDay(date)
    }

    private static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    var body: some View {
        SettingsPane(tab: .general) {
            SettingsForm {
                Section("Menu bar") {
                    SettingRow(hint: "While paused, permission requests, questions and inputs time out at once, and Claude is told you are away. Notifications and needs items still arrive. A pause ends at its time, or for Until I'm back, at the first keyboard or mouse input after a minute, or when you unlock the screen.") {
                        LabeledContent("Pause") {
                            HStack(spacing: 8) {
                                if let display = pause.display {
                                    // Each second, for the countdown before Until I'm back begins.
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        StatusPill(text: display.title(now: context.date, timeText: Coordinator.clockText), tone: Tone.orange.color)
                                    }
                                    Button(display.isPaused ? "Resume" : "Cancel") { pause.onResume() }
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    TimelineView(.everyMinute) { context in
                                        Menu("Pause stew") {
                                            ForEach(PauseChoice.menu(morningHour: model.config.pauseMorningHour), id: \.self) { choice in
                                                Button(choice.title(now: context.date, calendar: .current, timeText: Coordinator.clockText)) { pause.onPause(choice) }
                                            }
                                        }
                                        .fixedSize()
                                    }
                                }
                            }
                        }
                    }
                    SettingRow(hint: "Pause stew ▸ Until \(Self.hourText(model.config.pauseMorningHour)) ends at this hour: today while it is still ahead, else tomorrow.") {
                        Picker("Pause until morning", selection: binding(\.pauseMorningHour)) {
                            ForEach(Self.morningHours(including: model.config.pauseMorningHour), id: \.self) { hour in Text(Self.hourText(hour)).tag(hour) }
                        }
                    }
                    SettingRow(hint: "Shows what waits for you, with History, Settings and Pause. When off, it still appears while something needs you, and stew settings or opening Stew.app brings you here.") {
                        Toggle("Show in menu bar", isOn: binding(\.menuBar))
                    }
                    SettingRow(hint: "Monochrome takes the menu bar's color, like the system icons.") {
                        Picker("Icon", selection: binding(\.menuBarIcon)) {
                            Text("Color").tag(MenuBarIconStyle.color)
                            Text("Monochrome").tag(MenuBarIconStyle.monochrome)
                        }
                    }
                }
                Section("Timing") {
                    SettingRow(hint: "When it runs out, Claude is told you did not respond in time, so it can go another way. You can still answer it later from History. Applies to permission requests and questions.") {
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
                }
                Section("Panel") {
                    SettingRow(hint: nil) {
                        Picker("Position", selection: binding(\.position)) {
                            ForEach(Self.positions, id: \.1) { Text($0.0).tag($0.1) }
                        }
                    }
                    SettingRow(hint: PanelBackground.glassAvailable
                        ? "Glass lets the windows behind the panel show through, tinted so the text stays readable."
                        : "Glass needs macOS 26 or later. The panel stays solid.") {
                        Picker("Look", selection: binding(\.panelLook)) {
                            Text("Solid").tag(PanelLook.solid)
                            Text("Glass").tag(PanelLook.glass)
                        }
                        .disabled(!PanelBackground.glassAvailable)
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
                    SettingRow(hint: "A short burst when you approve a request.") {
                        Toggle("Confetti", isOn: binding(\.confetti))
                    }
                }
                Section("Updates") {
                    SettingRow(hint: updater.isReleaseBuild ? updater.installNote ?? (model.config.autoUpdate ? "stew checks once a day and installs a new version when no request is open." : "stew checks once a day and tells you when a new version is available.") : Updater.sourceBuildNote) {
                        Toggle("Install updates automatically", isOn: binding(\.autoUpdate))
                            .disabled(!updater.isReleaseBuild)
                    }
                    SettingRow(hint: updateHint) {
                        LabeledContent("Version") {
                            HStack(spacing: 8) {
                                Text(AppVersion.running.description).foregroundStyle(Ink.secondary)
                                if let available = updater.availableVersion, updater.isReleaseBuild {
                                    StatusPill(text: "\(available) available", tone: Tone.paprika.color)
                                }
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button(updater.busy ? "Checking…" : "Check now") { updater.run(install: false) { _ in } }
                            .disabled(updater.busy)
                        // Check now only reports; installing takes its own click.
                        if updater.availableVersion != nil, updater.isReleaseBuild, updater.installNote == nil {
                            Button("Install now") { updater.run(install: true) { _ in } }
                                .buttonStyle(.borderedProminent)
                                .disabled(updater.busy)
                        }
                    }
                }
            }
        }
    }

    /// When stew last looked for an update, and what it found.
    private var updateHint: String {
        guard let lastCheck = updater.state.lastCheck else { return "Never checked for updates." }
        let result = updater.state.lastResult.map { " \($0)" } ?? ""
        return "Last checked \(SettingsDate.text(lastCheck)).\(result)"
    }

    private func binding<Value: Hashable>(_ keyPath: WritableKeyPath<StewConfig, Value>) -> Binding<Value> {
        Binding(get: { model.config[keyPath: keyPath] }, set: { value in model.update { $0[keyPath: keyPath] = value } })
    }
}

struct KeySettings: View {
    @ObservedObject var model: SettingsModel

    private static let answering: [(HotkeyAction, String)] = [
        (.approve, "Approve or OK"),
        (.deny, "Deny"),
        (.other, "Note or Other…"),
        (.grant, "Allow more…"),
        (.extend, "More time"),
        (.submit, "Confirm or send"),
        (.enterSoon, "Give me 5 min"),
        (.enterLater, "I'll enter it later"),
    ]

    private static let moving: [(HotkeyAction, String)] = [
        (.previous, "Previous question"),
        (.next, "Next question"),
        (.dismiss, "Dismiss"),
        (.dismissAll, "Dismiss all"),
    ]

    var body: some View {
        SettingsPane(tab: .keys) {
            Button("Reset keys to defaults") { model.resetKeys() }
        } content: {
            SettingsForm {
                Section {
                    ForEach(Self.answering, id: \.0) { action, name in recorder(name, action) }
                } header: {
                    Text("Answer")
                } footer: {
                    Hint("Click a key, then press the new combination. It needs Control, Option or Command, so plain typing never answers a panel. Esc cancels.")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Move and dismiss") {
                    ForEach(Self.moving, id: \.0) { action, name in recorder(name, action) }
                }
                Section("Options") {
                    ForEach(0..<4, id: \.self) { index in
                        LabeledContent("Option \(index + 1)") {
                            KeyRecorder(shortcut: model.keymap.options[index]) { model.setOptionShortcut($0, at: index) }
                        }
                    }
                }
                Section("Hard deny") {
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
                }
            }
        }
    }

    private func recorder(_ name: String, _ action: HotkeyAction) -> some View {
        LabeledContent(name) {
            KeyRecorder(shortcut: model.keymap[action]) { model.setShortcut($0, for: action) }
        }
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
            (recording ? Text("Press keys…") : shortcut.text)
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

    private static let extraTimes: [(String, Double)] = [("Off", 0), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120)]

    private var strongApproveText: String {
        guard let keymap = try? Keymap(config: model.config) else { return "⇧⌘↩" }
        return keymap[.approve].adding(keymap.hardDenyExtra).description
    }

    private func classifierBinding<Value: Hashable>(_ keyPath: WritableKeyPath<StewConfig.ClassifierConfig, Value>) -> Binding<Value> {
        Binding(get: { model.config.classifier[keyPath: keyPath] }, set: { value in model.update { $0.classifier[keyPath: keyPath] = value } })
    }

    var body: some View {
        SettingsPane(tab: .claude) {
            SettingsForm {
                Section("Hooks") {
                    SettingRow(hint: "When auto mode blocks a call, stew asks you, and an approved call is retried once. Questions and things Claude needs you to do can come to stew too. Changes ~/.claude/settings.json; a backup is written first.") {
                        LabeledContent("Hooks") {
                            HStack(spacing: 8) {
                                switch model.hookState {
                                case .complete:
                                    StatusPill(text: "Installed", tone: Tone.green.color)
                                    Button("Uninstall") { model.setHooks(installed: false) }
                                case .partial:
                                    StatusPill(text: "Needs an update", tone: Tone.orange.color)
                                    Button("Update") { model.setHooks(installed: true) }
                                        .buttonStyle(.borderedProminent)
                                case .none:
                                    StatusPill(text: "Not installed", tone: Ink.secondary)
                                    Button("Install") { model.setHooks(installed: true) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                }
                Section("Questions and needs") {
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
                    SettingRow(hint: "When Claude ends a turn with a \"needs input:\" line, stew shows it as something that needs you, with its steps and commands. It goes away when you write to that session.") {
                        Picker("Needs you from Claude Code", selection: Binding(
                            get: { model.config.autoNeeds },
                            set: { value in model.update { $0.autoNeeds = value } }
                        )) {
                            Text("In stew for unattended sessions").tag(QuestionRouting.unattended)
                            Text("Always in stew").tag(QuestionRouting.always)
                            Text("Never").tag(QuestionRouting.never)
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
                    SettingRow(hint: "The check also rates how bad an action is if it runs: low, medium, high or critical risk, with a line on whether it can be undone. Critical actions take \(strongApproveText) to approve, like calls auto mode never allows.") {
                        Toggle("Stronger approve for critical", isOn: classifierBinding(\.criticalNeedsStrongApprove))
                    }
                    .disabled(!model.config.classifier.enabled)
                    SettingRow(hint: "Added to the time to answer for high and critical risk actions, so there is time to read them.") {
                        Picker("Extra time for high risk", selection: classifierBinding(\.highExtraTime)) {
                            ForEach(Self.extraTimes, id: \.1) { Text($0.0).tag($0.1) }
                        }
                    }
                    .disabled(!model.config.classifier.enabled)
                    SettingRow(hint: "Approve on the iPhone first shows the action, the command and whether it can be undone. For critical, you also hold Approve down.") {
                        Picker("Extra confirmation on iPhone", selection: classifierBinding(\.phoneConfirmation)) {
                            Text("High and critical").tag(SeverityRules.PhoneScope.highAndCritical)
                            Text("Critical only").tag(SeverityRules.PhoneScope.critical)
                            Text("Off").tag(SeverityRules.PhoneScope.off)
                        }
                    }
                    .disabled(!model.config.classifier.enabled)
                }
            }
        }
    }
}

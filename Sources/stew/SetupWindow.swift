import AppKit
import SwiftUI
import StewCore

extension SetupStep: PaneTab {
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .agents: "Agents"
        case .tryIt: "Try it"
        case .phone: "iPhone"
        case .done: "Done"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .agents: "terminal"
        case .tryIt: "hand.raised"
        case .phone: "iphone"
        case .done: "flag.checkered"
        }
    }
}

/// The setup window's state: the step on screen, what each agent has of stew, and how
/// the sample request ended.
final class SetupModel: ObservableObject {
    @Published var step: SetupStep = .welcome
    @Published private(set) var agents: [AgentSetup] = []
    /// `[features] hooks = false` in Codex's config.toml: Codex runs no hooks at all.
    @Published private(set) var codexHooksDisabled = false
    @Published private(set) var sampleOutcome: HistoryEntry.Outcome?
    @Published private(set) var error: String?
    /// Shows the sample request in the panel; the closure gets its answer.
    var onShowSample: ((StewRequest, @escaping (StewResponse) -> Void) -> Void)?
    var onOpenSettings: ((SettingsTab) -> Void)?
    /// Done on the last step: closes the window.
    var onDone: (() -> Void)?
    /// Set for `stew snapshot`: reloading keeps the sample agents.
    private var isSample = false

    func load() {
        guard !isSample else { return }
        agents = CodingAgent.allCases.map(Setup.agentSetup)
        codexHooksDisabled = CodexConfig.hooksDisabled(toml: (try? String(contentsOfFile: Hooks.codexConfigPath, encoding: .utf8)) ?? "")
    }

    /// Shows these states without reading the agents' files, for `stew snapshot`.
    func showSample(step: SetupStep, agents: [AgentSetup] = [], codexHooksDisabled: Bool = false, sampleOutcome: HistoryEntry.Outcome? = nil) {
        isSample = true
        self.step = step
        self.agents = agents
        self.codexHooksDisabled = codexHooksDisabled
        self.sampleOutcome = sampleOutcome
    }

    func agent(_ agent: CodingAgent) -> AgentSetup? {
        agents.first { $0.agent == agent }
    }

    func install(_ agent: CodingAgent) {
        do {
            try Setup.installAgent(agent)
            error = nil
        } catch {
            self.error = "Could not install for \(agent.productName): \(error)"
        }
        load()
    }

    func showSampleRequest() {
        let request = SetupGuide.sampleRequest(agent: SetupGuide.sampleAgent(agents))
        onShowSample?(request) { [weak self] response in
            self?.sampleOutcome = HistoryEntry.outcome(of: response)
        }
    }

    /// Timing out is not trying it: the user never answered.
    var sampleAnswered: Bool { sampleOutcome.map { $0 != .timedOut } ?? false }

    func isDone(_ step: SetupStep, phonePaired: Bool) -> Bool {
        SetupGuide.isDone(step, agents: agents, sampleAnswered: sampleAnswered, phonePaired: phonePaired)
    }
}

/// The setup window: a normal window, so it takes the keyboard only when the user opens
/// it. When stew opens it by itself at start, it comes up without taking the keyboard
/// from the app in front, as the panel does.
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let setup = SetupModel()
    private let settings = SettingsModel()
    private var window: NSWindow?

    init(onSaved: @escaping () -> Void, onShowSample: @escaping (StewRequest, @escaping (StewResponse) -> Void) -> Void, onOpenSettings: @escaping (SettingsTab) -> Void) {
        super.init()
        settings.onSaved = onSaved
        setup.onShowSample = onShowSample
        setup.onOpenSettings = onOpenSettings
        setup.onDone = { [weak self] in self?.window?.close() }
    }

    /// The size the window opens at.
    static let size = CGSize(width: 760, height: 600)

    /// `activate` is true for the user's own action (the menu, Settings, opening
    /// Stew.app). False at start: the window shows behind the app the user works in.
    func show(activate: Bool) {
        settings.load()
        setup.load()
        if window?.isVisible != true { setup.step = .welcome }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.size),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Set up stew"
            // As in Settings: the title bar and the step bar read as one toolbar.
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SetupView(setup: setup, settings: settings))
            window.center()
            self.window = window
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    /// Closing the window, also before the last step, means the user has seen it, so it
    /// no longer opens by itself.
    func windowWillClose(_ notification: Notification) {
        // Settings may have changed the file since this window loaded it.
        settings.load()
        guard !settings.config.setup.completed else { return }
        settings.update { $0.setup.completed = true }
    }

    /// The agents may change while the window is open, such as Codex installed meanwhile.
    func windowDidBecomeKey(_ notification: Notification) {
        setup.load()
    }
}

struct SetupView: View {
    @ObservedObject var setup: SetupModel
    @ObservedObject var settings: SettingsModel
    var account: AccountModel = .shared
    var link: PhoneLink = .shared
    /// Signed in and paired, for `stew snapshot`.
    var phoneSample: (signedIn: Bool, paired: Bool)?

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(tabs: SetupStep.allCases, selection: $setup.step) { step in
                setup.isDone(step, phonePaired: phoneState.paired)
            }
            Divider()
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = setup.error ?? settings.error {
                Notice(.error, error)
                    .padding(.horizontal, SettingsMetrics.inset)
                    .padding(.bottom, 14)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.paprika)
        .frame(minWidth: 640, minHeight: 520)
    }

    private var phoneState: (signedIn: Bool, paired: Bool) {
        phoneSample ?? (account.signedIn, !link.paired.isEmpty)
    }

    @ViewBuilder
    private var pane: some View {
        switch setup.step {
        case .welcome: SetupWelcome()
        case .agents: SetupAgents(setup: setup)
        case .tryIt: SetupTryIt(setup: setup, settings: settings)
        case .phone: SetupPhone(setup: setup, signedIn: phoneState.signedIn, paired: phoneState.paired)
        case .done: SetupDone(settings: settings)
        }
    }

    /// Back, and the way on: Skip while a step's work is not done, Continue once it is.
    private var footer: some View {
        HStack(spacing: 8) {
            Text("Step \(SetupStep.allCases.firstIndex(of: setup.step).map { $0 + 1 } ?? 1) of \(SetupStep.allCases.count)")
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
            Spacer()
            if let previous = setup.step.previous {
                Button("Back") { setup.step = previous }
            }
            if let next = setup.step.next {
                Button(skips ? "Skip" : "Continue") { setup.step = next }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { setup.onDone?() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.vertical, 12)
    }

    /// A step with work to do that is not done yet.
    private var skips: Bool {
        switch setup.step {
        case .welcome, .done: false
        case .agents, .tryIt, .phone: !setup.isDone(setup.step, phonePaired: phoneState.paired)
        }
    }
}

private struct SetupWelcome: View {
    var body: some View {
        SettingsPane(symbol: SetupStep.welcome.symbol, title: "Welcome to stew", subtitle: "A few steps to set it up. Skip any of them, and come back from the menu bar icon or Settings ▸ General.") {
            SettingsForm {
                Section {
                    Text("stew shows what Claude Code and Codex ask you in a small panel at the top of the screen: permission requests, questions, and things only you can do, such as logging in.")
                    Text("You answer with a key, from any app. The panel never takes the keyboard from what you are typing.")
                    Text("Next, connect your agents, try a sample request, and see what the iPhone app adds.")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SetupAgents: View {
    @ObservedObject var setup: SetupModel

    var body: some View {
        SettingsPane(symbol: SetupStep.agents.symbol, title: "Agents", subtitle: "Install the stew skill and hooks, so your agents ask you through stew.") {
            SettingsForm {
                ForEach(CodingAgent.allCases, id: \.self) { agent in
                    if let state = setup.agent(agent) {
                        Section(agent.productName) {
                            SettingRow(hint: Self.hint(state)) {
                                LabeledContent("Skill and hooks") { controls(state) }
                            }
                            if state.needsTrust {
                                Notice(.error, "Codex runs these hooks only after you trust them. Open Codex, type /hooks, and trust the stew entries.")
                            }
                            if agent == .codex, state.hooks != .none, setup.codexHooksDisabled {
                                Notice(.error, "Hooks are off in \(SessionResolver.abbreviate(Hooks.codexConfigPath, home: Paths.home)) ([features] hooks = false), so Codex runs none of them.")
                            }
                        }
                    }
                }
            }
        }
    }

    /// The agent's state, with the button that sets it up when there is something to do.
    @ViewBuilder
    private func controls(_ state: AgentSetup) -> some View {
        HStack(spacing: 8) {
            switch state.status {
            case .notFound:
                // An agent with its command but no folder is there, only not run yet.
                StatusPill(text: state.presence == .commandOnly ? "Not installed" : "Not found", tone: Ink.secondary)
            case .notInstalled:
                StatusPill(text: "Not installed", tone: Ink.secondary)
            case .partlyInstalled:
                StatusPill(text: "Partly installed", tone: Tone.orange.color)
            case .needsUpdate:
                StatusPill(text: "Needs an update", tone: Tone.orange.color)
            case .installed:
                StatusPill(text: "Installed", tone: Tone.green.color)
            }
            if state.canInstall {
                Button(state.status == .needsUpdate ? "Update" : "Install") { setup.install(state.agent) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    static func hint(_ state: AgentSetup) -> String {
        let location = Setup.skillLocation(for: state.agent)
        let folder = location.displayFolder
        let command = state.agent == .claudeCode ? "claude" : "codex"
        switch state.presence {
        case .missing:
            return "No \(folder) folder or \(command) command found. Install \(state.agent.productName), then come back to this step."
        case .commandOnly:
            return "Found the \(command) command, but no \(folder) folder yet. Open \(state.agent.productName) once, then come back to this step."
        case .configured:
            break
        }
        let hookFile = SessionResolver.abbreviate(Hooks.hookFilePath(for: state.agent), home: Paths.home)
        var parts: [String] = []
        if state.status == .partlyInstalled {
            parts.append(state.skillInstalled ? "The skill is in place, the hooks are not." : "The hooks are in place, the skill is not.")
        }
        switch state.agent {
        case .claudeCode:
            parts.append("The skill lets Claude ask you through stew. The hooks ask you when auto mode blocks a call. Changes \(hookFile); a backup is written first.")
        case .codex:
            parts.append("The skill lets Codex ask you through stew. The hooks ask you before Codex asks for approval. Changes \(hookFile); a backup is written first.")
        }
        if let minimum = state.agent.minimumVersion {
            parts.append("Needs \(state.agent.productName) \(minimum) or later.")
        }
        return parts.joined(separator: " ")
    }
}

private struct SetupTryIt: View {
    @ObservedObject var setup: SetupModel
    @ObservedObject var settings: SettingsModel

    /// The panel's answering keys, by the names Settings ▸ Keys gives them.
    private static let keys: [(HotkeyAction, String)] = [
        (.approve, "Approve or OK"),
        (.deny, "Deny"),
        (.other, "Note or Other…"),
        (.extend, "More time"),
        (.dismiss, "Dismiss"),
    ]

    private var position: String {
        switch settings.config.position {
        case "top-center": "top center"
        case "top-left": "top left"
        default: "top right"
        }
    }

    var body: some View {
        SettingsPane(symbol: SetupStep.tryIt.symbol, title: "Try it", subtitle: "See a request in the panel and answer it with a key.") {
            SettingsForm {
                Section("Panel") {
                    SettingRow(hint: "Shows a sample permission request at the \(position) of the screen. Nothing runs, and no agent gets your answer.") {
                        LabeledContent("Sample request") {
                            HStack(spacing: 8) {
                                if let outcome = setup.sampleOutcome {
                                    StatusPill(text: outcome.label(for: SetupGuide.sampleAgent(setup.agents)), tone: outcome.tone)
                                }
                                Button("Show sample") { setup.showSampleRequest() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
                Section {
                    ForEach(Self.keys, id: \.0) { action, name in
                        LabeledContent(name) { Keycap(shortcut: settings.keymap[action]) }
                    }
                    LabeledContent("Options") {
                        HStack(spacing: 4) {
                            ForEach(Array(settings.keymap.options.enumerated()), id: \.offset) { _, shortcut in Keycap(shortcut: shortcut) }
                        }
                    }
                } header: {
                    Text("Keys")
                } footer: {
                    Hint("They work from any app while a panel shows, and do nothing otherwise. Change them in Settings ▸ Keys.")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct SetupPhone: View {
    @ObservedObject var setup: SetupModel
    let signedIn: Bool
    let paired: Bool

    var body: some View {
        SettingsPane(symbol: SetupStep.phone.symbol, title: "iPhone", subtitle: "Optional: answer requests on your iPhone while you are away from the Mac.") {
            SettingsForm {
                Section {
                    SettingRow(hint: "The iPhone app needs a stew account, with a plan after the free trial. Everything else in stew is free.") {
                        LabeledContent("Account") {
                            HStack(spacing: 8) {
                                StatusPill(text: signedIn ? "Signed in" : "Not signed in", tone: signedIn ? Tone.green.color : Ink.secondary)
                                Button("Open Account") { setup.onOpenSettings?(.account) }
                            }
                        }
                    }
                    SettingRow(hint: "Pair it in Settings ▸ iPhone with the code shown there.") {
                        LabeledContent("iPhone") {
                            HStack(spacing: 8) {
                                StatusPill(text: paired ? "Paired" : "Not paired", tone: paired ? Tone.green.color : Ink.secondary)
                                Button("Open iPhone") { setup.onOpenSettings?(.phone) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct SetupDone: View {
    @ObservedObject var settings: SettingsModel

    private static let help = URL(string: "https://stewcli.com/help")!

    var body: some View {
        let iconShown = settings.config.menuBar
        SettingsPane(symbol: SetupStep.done.symbol, title: "Done", subtitle: "stew runs in the background and shows the panel when an agent asks.") {
            SettingsForm {
                Section {
                    SettingRow(hint: iconShown
                        ? "In the menu bar at the top of the screen. Click it for what waits for you; right-click it for History, Settings and Pause."
                        : "It shows only while something needs you. Turn it on with Show in menu bar in Settings ▸ General.") {
                        LabeledContent("Menu bar icon") {
                            if iconShown {
                                Image(nsImage: StatusIcon.image(for: MenuBarIcon(monochrome: settings.config.menuBarIcon == MenuBarIconStyle.monochrome)))
                            } else {
                                StatusPill(text: "Hidden", tone: Ink.secondary)
                            }
                        }
                    }
                    SettingRow(hint: iconShown ? "Opening Stew.app again, or running stew settings, also opens it." : "Running stew settings also opens it.") {
                        LabeledContent("Settings") {
                            Text(iconShown ? "Right-click the icon, then Settings…" : "Open Stew.app").foregroundStyle(Ink.secondary)
                        }
                    }
                    SettingRow(hint: iconShown ? "Also in Settings ▸ General." : "Set up stew… there opens this window again.") {
                        LabeledContent("This setup") {
                            Text(iconShown ? "Right-click the icon, then Set up stew…" : "Settings ▸ General").foregroundStyle(Ink.secondary)
                        }
                    }
                    SettingRow(hint: "Guides and answers to common questions.") {
                        LabeledContent("Help") {
                            Link("stewcli.com/help", destination: Self.help)
                        }
                    }
                }
            }
        }
    }
}

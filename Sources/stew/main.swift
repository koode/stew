import AppKit
import Foundation
import StewCore

let usage = """
stew: ask the user for permission, tell them something, or ask a question, in a
floating panel that never takes keyboard focus. Answers print as one JSON line.
Add --help to a command (or run stew help COMMAND) for only its part of this text.

USAGE
  stew permit --action TEXT --reason TEXT [--command TEXT|-] [common]
  stew notify TITLE [--body TEXT] [--level info|success|warning|error] [--wait] [common]
  stew ask [--json JSON | --file PATH | stdin] [common]
      Input has the AskUserQuestion shape: {"questions":[{"question","header",
      "options":[{"label","description","preview"?}],"multiSelect"}]}
  stew needs TITLE [--why TEXT] [--step TEXT]... [--command CMD|-]... [--link URL]...
             [--done LABEL] [--answer LABEL]... [--wait [--timeout SECONDS]] [--session NAME]
      Tell the user you need them to do something only they can do (log in, buy,
      approve in a web page, a physical action). Returns at once with the item's
      id; it stays open, also across restarts, until it is resolved. --wait blocks
      until the user marks it done ("done", with their note) or declines it
      ("dismissed"); --timeout limits only that wait.
      --done names the Done button after the state the user reaches ("Signed in",
      at most 24 characters). --answer (up to 3, at most 40 characters each) adds
      another way it can end ("Can't sign in"), on ⌘1 to ⌘3. With either, the
      answer names the label the user picked: "done" with the --done label, or
      "answered" with one of the --answer labels.
  stew needs list [--json]       The open items.
  stew needs resolve ID          Clear an item once you can see it is done.
  stew check --action TEXT --reason TEXT [--command TEXT|-]
      Run only the auto mode risk check and print its verdict.
  stew keys          Show the shortcuts in effect.
  stew settings      Open the settings window (time limit, keys, hooks, risk check).
  stew approvals     Open the settings window on the list of standing approvals.
  stew history [--missed] [--json]
      Open the settings window on the history of finished requests. --missed
      shows only those that timed out. --json prints them as a JSON array instead.
  stew hooks install|uninstall|status
      Ask in stew when Claude Code's auto mode blocks a call (hooks in
      ~/.claude/settings.json; a backup is written first).
  stew hook denied|pre|question|stop|prompt
      The hook commands Claude Code runs. Not for direct use.
  stew stop          Stop the daemon.
  stew daemon        Run the daemon (the LaunchAgent does this).
  stew version       Print the version and build (also --version).
  stew update [--check]
      Install the latest version now (the daemon also checks daily), or with
      --check only report whether there is one.
  stew uninstall [--bin-dir DIR] [--app-dir DIR]
      Remove the hooks, daemon, Stew.app, the stew link, skill, caches and
      stored approvals. Keeps ~/.config/stew.
  stew completions fish|zsh|bash
      Print the shell completion script.
  stew completions install|uninstall
      Write the fish and zsh scripts where those shells load them, or remove
      them. The installers do this.

COMMON
  --session NAME     Label for the panel. Default: the Claude job name or folder.
  --timeout SECONDS  Time to answer once on screen (default: responseTimeout in
                     the config, 1 min, for permit and ask). 0 means no limit.
                     When it runs out the answer is "timeout" with a note for
                     Claude. The user can add time with ⌘E.

EXIT CODES
  0 approved / answered / acknowledged / shown / done / resolved, 1 denied, 2 dismissed,
  3 timeout, 4 error
  stew update: 0 up to date or installed, 10 update available (--check),
  11 newer version needs a newer macOS, 12 installs once no request is open,
  20 check failed, 21 download rejected by verification, 22 install failed
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    /// Every value of an option that may repeat, such as `needs --step`, in order.
    var lists: [String: [String]] = [:]
    var flags: Set<String> = []

    static let booleanFlags: Set<String> = ["wait", "help", "check"]

    /// Flags that take no value for one command only. `ask --json` takes JSON, while
    /// `history --json` is a switch.
    static func booleanFlags(for command: String) -> Set<String> {
        switch command {
        case "history": booleanFlags.union(["missed", "json"])
        case "needs": booleanFlags.union(["json"])
        default: booleanFlags
        }
    }

    init(_ arguments: ArraySlice<String>, booleanFlags: Set<String> = Arguments.booleanFlags) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    let key = String(name[..<equals])
                    let value = String(name[name.index(after: equals)...])
                    options[key] = value
                    lists[key, default: []].append(value)
                } else if booleanFlags.contains(name) {
                    flags.insert(name)
                } else {
                    guard let value = iterator.next() else { throw UsageError("--\(name) needs a value") }
                    options[name] = value
                    lists[name, default: []].append(value)
                }
            } else {
                positional.append(argument)
            }
        }
    }

    func required(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else { throw UsageError("missing --\(name)") }
        return value
    }

    var timeout: Double? {
        get throws {
            guard let text = options["timeout"] else { return nil }
            guard let value = Double(text), value >= 0 else { throw UsageError("--timeout must be 0 (no limit) or a positive number") }
            return value
        }
    }
}

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func readStandardInput() -> String {
    String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

func currentSession(_ arguments: Arguments) -> SessionInfo {
    SessionResolver.resolve(
        explicitName: arguments.options["session"],
        environment: ProcessInfo.processInfo.environment,
        cwd: FileManager.default.currentDirectoryPath,
        home: Paths.home,
        readFile: { FileManager.default.contents(atPath: $0) }
    )
}

func permissionRequest(_ arguments: Arguments) throws -> PermissionRequest {
    var command = arguments.options["command"]
    if command == "-" { command = readStandardInput().trimmingCharacters(in: .newlines) }
    return PermissionRequest(action: try arguments.required("action"), command: command, reason: try arguments.required("reason"))
}

func emit(_ response: StewResponse) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(response) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
    exit(response.exitCode)
}

func loadConfig() -> (StewConfig, String?) {
    guard let data = FileManager.default.contents(atPath: Paths.config) else { return (StewConfig(), nil) }
    do {
        let config = try JSONDecoder().decode(StewConfig.self, from: data)
        _ = try Keymap(config: config)
        return (config, nil)
    } catch {
        return (StewConfig(), "\(Paths.config): \(error)")
    }
}

/// Runs an update in this process, for `stew update --check` and when no daemon answers.
func updateInProcess(install: Bool) -> UpdateOutcome {
    let updater = Updater { message in Log.append(message) }
    var result: UpdateOutcome?
    updater.run(install: install) { outcome in result = outcome }
    // The updater reports on the main queue, so keep the main run loop turning.
    while result == nil {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return result!
}

/// Release tooling: makes a new release signing key pair. The public key goes to
/// --public-key-file (or stderr). The private key goes to stdout, as a bare base64
/// value or, with --1password-title, as an item template for `op item create`, so the
/// release script can pipe it into 1Password without writing it to disk.
func updateKeygen(_ arguments: Arguments) throws {
    let keys = UpdateSigner.generateKeyPair()
    if let path = arguments.options["public-key-file"] {
        try (keys.publicKey + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    } else {
        FileHandle.standardError.write(Data("public key: \(keys.publicKey)\n".utf8))
    }
    guard let title = arguments.options["1password-title"] else {
        print(keys.privateKey)
        return
    }
    let template: [String: Any] = [
        "title": title,
        "category": "SECURE_NOTE",
        "fields": [
            ["id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain",
             "value": "Ed25519 key that signs stew update zips. The public key is Updater.embeddedPublicKey in Sources/stew/Updater.swift."],
            ["id": "private_key", "type": "CONCEALED", "label": "private key", "value": keys.privateKey],
            ["id": "public_key", "type": "STRING", "label": "public key", "value": keys.publicKey],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: template, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// `stew needs`: show a new item, or list and resolve open ones.
func runNeeds(_ arguments: Arguments) throws {
    switch arguments.positional.first {
    case "list" where arguments.options["title"] == nil:
        let open = NeedsStore.readFile()
        if arguments.flags.contains("json") {
            FileHandle.standardOutput.write(try NeedsBook.encode(open))
        } else if open.isEmpty {
            print("Nothing needs you.")
        } else {
            for record in open {
                print("\(record.id)  \(record.menuTitle)\(record.parked ? "  (not now)" : "")")
            }
        }
    case "resolve" where arguments.options["title"] == nil:
        guard arguments.positional.count == 2 else { throw UsageError("needs resolve takes one ID") }
        let id = arguments.positional[1]
        guard let reply = Client.sendControl("needs resolve \(id)", startDaemon: true),
              let response = try? Wire.decode(StewResponse.self, line: Data(reply.utf8)) else {
            emit(StewResponse(status: .error, id: id, error: "could not reach the daemon"))
        }
        emit(response)
    default:
        let title = arguments.options["title"] ?? arguments.positional.first
        guard let title, !title.isEmpty else { throw UsageError("needs needs a title, or list or resolve ID") }
        guard arguments.positional.count <= (arguments.options["title"] == nil ? 1 : 0) else {
            throw UsageError("needs takes one title; quote it, and pass details with --why and --step")
        }
        var commands = arguments.lists["command"] ?? []
        if let stdinIndex = commands.firstIndex(of: "-") {
            commands[stdinIndex] = readStandardInput().trimmingCharacters(in: .newlines)
        }
        if (arguments.lists["done"] ?? []).count > 1 { throw UsageError("needs takes one --done; add other outcomes with --answer") }
        let needs = NeedsRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            why: arguments.options["why"],
            steps: arguments.lists["step"] ?? [],
            commands: commands.map { NeedsCommand(command: $0) },
            links: (arguments.lists["link"] ?? []).map { NeedsLink(url: $0) },
            doneLabel: arguments.options["done"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            answers: (arguments.lists["answer"] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        do {
            try needs.validate()
        } catch {
            throw UsageError("\(error)")
        }
        let wait = arguments.flags.contains("wait")
        let timeout = try arguments.timeout
        if timeout != nil, !wait { throw UsageError("--timeout applies only with --wait; a needs item has no time limit") }
        emit(Client.send(StewRequest(session: currentSession(arguments), prompt: .needs(needs), timeout: timeout, wait: wait)))
    }
}

func runCommand(_ command: String, _ arguments: Arguments) throws {
    switch command {
    case "permit":
        let request = StewRequest(session: currentSession(arguments), prompt: .permission(try permissionRequest(arguments)), timeout: try arguments.timeout)
        emit(Client.send(request))

    case "notify":
        let title = arguments.options["title"] ?? arguments.positional.first
        guard let title, !title.isEmpty else { throw UsageError("notify needs a title") }
        let levelText = arguments.options["level"] ?? "info"
        guard let level = NotifyLevel(rawValue: levelText) else { throw UsageError("unknown --level \(levelText)") }
        let body = arguments.options["body"] ?? (arguments.positional.count > 1 ? arguments.positional[1] : nil)
        let request = StewRequest(
            session: currentSession(arguments),
            prompt: .notify(NotifyRequest(title: title, body: body, level: level)),
            timeout: try arguments.timeout,
            wait: arguments.flags.contains("wait")
        )
        emit(Client.send(request))

    case "ask":
        let text: String
        if let json = arguments.options["json"] {
            text = json
        } else if let file = arguments.options["file"] {
            guard let data = FileManager.default.contents(atPath: file) else { throw UsageError("cannot read \(file)") }
            text = String(decoding: data, as: UTF8.self)
        } else if isatty(0) == 0 {
            text = readStandardInput()
        } else {
            throw UsageError("ask needs --json, --file or JSON on stdin")
        }
        let questionSet: QuestionSet
        do {
            questionSet = try JSONDecoder().decode(QuestionSet.self, from: Data(text.utf8))
        } catch {
            throw UsageError("invalid question JSON: \(error)")
        }
        try questionSet.validate()
        emit(Client.send(StewRequest(session: currentSession(arguments), prompt: .question(questionSet), timeout: try arguments.timeout)))

    case "needs":
        try runNeeds(arguments)

    case "check":
        let (config, _) = loadConfig()
        let session = currentSession(arguments)
        let semaphore = DispatchSemaphore(value: 0)
        var output = StewResponse(status: .error)
        RiskChecker(config: config.classifier).check(try permissionRequest(arguments), session: session) { result in
            switch result {
            case .success(let assessment): output = StewResponse(status: .shown, risk: assessment)
            case .failure(let error): output = StewResponse(status: .error, error: "\(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        emit(output)

    case "keys":
        let (config, configError) = loadConfig()
        let keymap = try Keymap(config: config)
        if let configError { print("config error, using defaults: \(configError)\n") }
        print("Config: \(Paths.config)\n")
        for action in HotkeyAction.allCases {
            print("  \(keymap[action].description.padding(toLength: 8, withPad: " ", startingAt: 0)) \(action.rawValue)")
        }
        print("  \(keymap.options.map(\.description).joined(separator: " ")) options 1-4")
        print("  approve gets +\(keymap.hardDenyExtra.symbols) when the check says auto mode would hard deny")

    case "_control":
        // Test hook: the daemon accepts simulated input only in headless mode.
        print(Client.sendControl(arguments.positional.joined(separator: " ")) ?? "daemon not running")

    case "hook":
        switch arguments.positional.first {
        case "denied": Hooks.denied()
        case "pre": Hooks.pre()
        case "question": Hooks.question()
        case "stop": Hooks.stop()
        case "stop-late": Hooks.stopLate()
        case "prompt": Hooks.prompt()
        default: throw UsageError("hook needs denied, pre, question, stop, stop-late or prompt")
        }

    case "hooks":
        switch arguments.positional.first {
        case "install": try Hooks.install()
        case "uninstall": try Hooks.uninstall()
        case "status", nil: Hooks.status()
        default: throw UsageError("hooks needs install, uninstall or status")
        }

    case "approvals", "settings":
        print(Client.sendControl(command, startDaemon: true) ?? "could not reach the daemon")

    case "history":
        let missedOnly = arguments.flags.contains("missed")
        if arguments.flags.contains("json") {
            let entries = History.filtered(HistoryStore.readFile(), missedOnly: missedOnly)
            FileHandle.standardOutput.write(try History.json(entries) + Data("\n".utf8))
        } else {
            print(Client.sendControl(missedOnly ? "history missed" : "history", startDaemon: true) ?? "could not reach the daemon")
        }

    case "stop":
        print(Client.sendControl("stop") ?? "daemon not running")

    case "daemon":
        Daemon.run()

    case "version", "--version":
        print("stew \(AppVersion.running)")

    case "update":
        let outcome: UpdateOutcome
        if arguments.flags.contains("check") {
            outcome = updateInProcess(install: false)
        } else if let reply = Client.sendControl("update"),
                  let decoded = try? Wire.decode(UpdateOutcome.self, line: Data(reply.utf8)) {
            // The daemon installs, because only it knows whether a request is open.
            outcome = decoded
        } else {
            outcome = updateInProcess(install: true)
        }
        print(outcome.message)
        exit(outcome.exitCode)

    case "uninstall":
        exit(Uninstaller.run(
            binDirectory: arguments.options["bin-dir"] ?? Paths.home + "/.local/bin",
            appDirectory: arguments.options["app-dir"] ?? Paths.home + "/Applications"
        ))

    case "completions":
        switch arguments.positional.first {
        case "install": exit(CompletionInstaller.install())
        case "uninstall": exit(CompletionInstaller.uninstall() == 0 ? 0 : 1)
        case let name?:
            guard let shell = CompletionShell(rawValue: name) else { throw UsageError("completions needs fish, zsh, bash, install or uninstall") }
            print(CompletionScript.script(for: shell), terminator: "")
        case nil: throw UsageError("completions needs fish, zsh, bash, install or uninstall")
        }

    case "_sign-update":
        // Release tooling: the private key arrives on stdin and never touches disk.
        guard let path = arguments.positional.first, let data = FileManager.default.contents(atPath: path) else {
            throw UsageError("_sign-update needs a readable file")
        }
        print(try UpdateSigner.sign(data, privateKey: readStandardInput()))

    case "_verify-update":
        guard let path = arguments.positional.first, let data = FileManager.default.contents(atPath: path) else {
            throw UsageError("_verify-update needs a readable file")
        }
        let archive = UpdateManifest.Archive(url: "", sha256: UpdateVerifier.sha256Hex(data), size: data.count, ed25519: try arguments.required("signature"))
        try UpdateVerifier.verify(data, against: archive, publicKey: try arguments.required("public-key"))
        print("signature valid")

    case "_update-keygen":
        try updateKeygen(arguments)

    case "snapshot":
        Snapshot.render(to: try arguments.required("out"))

    default:
        throw UsageError("unknown command \(command)")
    }
}

let commandLine = CommandLine.arguments
if LaunchContext.isOpenedAsApp(arguments: commandLine, parentProcessID: getppid(), inputIsTerminal: isatty(0) == 1) {
    // Double-clicking Stew.app opens the settings window in the daemon, starting it if needed.
    exit(Client.sendControl("settings", startDaemon: true) == nil ? 1 : 0)
}
guard commandLine.count > 1, !["-h", "--help"].contains(commandLine[1]) else {
    print(usage)
    exit(commandLine.count > 1 ? 0 : 64)
}
// `stew help [COMMAND]` and `stew COMMAND --help` print help and run nothing.
let helpTopic: String? = commandLine[1] == "help" ? (commandLine.count > 2 ? commandLine[2] : "") :
    (CommandHelp.isRequested(Array(commandLine.dropFirst(2))) ? commandLine[1] : nil)
if let helpTopic {
    if helpTopic.isEmpty {
        print(usage)
        exit(0)
    }
    guard let help = CommandHelp.text(for: helpTopic, usage: usage) else {
        FileHandle.standardError.write(Data("stew: unknown command \(helpTopic)\n\nRun `stew --help` for usage.\n".utf8))
        exit(64)
    }
    print(help)
    exit(0)
}
do {
    try runCommand(commandLine[1], try Arguments(commandLine.dropFirst(2), booleanFlags: Arguments.booleanFlags(for: commandLine[1])))
} catch {
    FileHandle.standardError.write(Data("stew: \(error)\n\nRun `stew --help` for usage.\n".utf8))
    exit(64)
}

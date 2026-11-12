import AppKit
import Foundation
import StewCore

let usage = """
stew: ask the user for permission, tell them something, or ask a question, in a
floating panel that never takes keyboard focus. Answers print as one JSON line.

USAGE
  stew permit --action TEXT --reason TEXT [--command TEXT|-] [common]
  stew notify TITLE [--body TEXT] [--level info|success|warning|error] [--wait] [common]
  stew ask [--json JSON | --file PATH | stdin] [common]
      Input has the AskUserQuestion shape: {"questions":[{"question","header",
      "options":[{"label","description","preview"?}],"multiSelect"}]}
  stew check --action TEXT --reason TEXT [--command TEXT|-]
      Run only the auto mode risk check and print its verdict.
  stew keys          Show the shortcuts in effect.
  stew settings      Open the settings window (time limit, keys, hooks, risk check).
  stew approvals     Open the settings window on the list of standing approvals.
  stew hooks install|uninstall|status
      Ask in stew when Claude Code's auto mode blocks a call (hooks in
      ~/.claude/settings.json; a backup is written first).
  stew hook denied|pre|question
      The hook commands Claude Code runs. Not for direct use.
  stew stop          Stop the daemon.
  stew daemon        Run the daemon (the LaunchAgent does this).
  stew version       Print the version and build (also --version).

COMMON
  --session NAME     Label for the panel. Default: the Claude job name or folder.
  --timeout SECONDS  Time to answer once on screen (default: responseTimeout in
                     the config, 1 min, for permit and ask). 0 means no limit.
                     When it runs out the answer is "timeout" with a note for
                     Claude. The user can add time with ⌘E.

EXIT CODES
  0 approved / answered / acknowledged / shown, 1 denied, 2 dismissed,
  3 timeout, 4 error
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let booleanFlags: Set<String> = ["wait", "help"]

    init(_ arguments: ArraySlice<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    options[String(name[..<equals])] = String(name[name.index(after: equals)...])
                } else if Self.booleanFlags.contains(name) {
                    flags.insert(name)
                } else {
                    guard let value = iterator.next() else { throw UsageError("--\(name) needs a value") }
                    options[name] = value
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
        default: throw UsageError("hook needs denied, pre or question")
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

    case "stop":
        print(Client.sendControl("stop") ?? "daemon not running")

    case "daemon":
        Daemon.run()

    case "version", "--version":
        print("stew \(AppVersion.running)")

    case "snapshot":
        Snapshot.render(to: try arguments.required("out"))

    default:
        throw UsageError("unknown command \(command)")
    }
}

let commandLine = CommandLine.arguments
guard commandLine.count > 1, !["-h", "--help", "help"].contains(commandLine[1]) else {
    print(usage)
    exit(commandLine.count > 1 ? 0 : 64)
}
do {
    try runCommand(commandLine[1], try Arguments(commandLine.dropFirst(2)))
} catch {
    FileHandle.standardError.write(Data("stew: \(error)\n\nRun `stew --help` for usage.\n".utf8))
    exit(64)
}

import Foundation

/// What a value on the command line can be, so shell completion knows what to offer.
public enum CompletionValue: Equatable, Sendable {
    /// Free text: offer nothing, not even file names.
    case text
    case file
    case directory
    case choices([String])
    /// The id of an open needs item, read from `stew needs list` while completing.
    case needsID
}

public struct CompletionOption: Sendable {
    /// Without the leading dashes.
    public let name: String
    public let summary: String
    /// Nil for a switch that takes no value.
    public let value: CompletionValue?
    public let repeats: Bool
}

public struct CompletionCommand: Sendable {
    public let name: String
    public let summary: String
    public let options: [CompletionOption]
    public let subcommands: [CompletionCommand]
    /// What the first word after the command takes when it is not a subcommand.
    public let argument: CompletionValue?
    /// In the usage text, but not offered: the commands that the agents and launchd run.
    public let hidden: Bool

    public var visibleSubcommands: [CompletionCommand] { subcommands.filter { !$0.hidden } }

    public func subcommand(_ name: String) -> CompletionCommand? {
        subcommands.first { $0.name == name }
    }
}

/// Every command, subcommand and option of `stew` that the usage text in main.swift
/// documents, with what their values take. Shell completion is generated from this
/// table, and a test checks it against the usage text in both directions, so a new
/// command or option has to go in both places. Commands starting with `_` are internal
/// and stay out of both.
public enum CommandTable {
    public static let root = command("stew", "Ask, tell or notify the user in a floating panel", options: [
        flag("version", "Print the version and build"),
    ], subcommands: [
        command("permit", "Ask the user for permission", options: [
            action, reason, permitCommand, session, timeout,
        ]),
        command("notify", "Tell the user something", options: [
            option("body", "Text under the title"),
            option("level", "How the panel looks", value: .choices(["info", "success", "warning", "error"])),
            flag("wait", "Wait until the user closes it"),
            session, timeout,
        ], argument: .text),
        command("ask", "Ask questions in the AskUserQuestion shape", options: [
            option("json", "The questions as JSON"),
            option("file", "Read the questions from a file", value: .file),
            session, timeout,
        ]),
        command("input", "Ask for one typed answer", options: [
            option("why", "Why you need it"),
            option("placeholder", "Grey text in the empty field"),
            option("default", "Text the field starts with"),
            option("pattern", "A regular expression the whole answer must match"),
            option("format", "What the pattern expects, in plain words"),
            flag("secret", "A password or token: masked, never stored"),
            flag("multiline", "Return adds a line"),
            session, timeout,
        ], argument: .text),
        command("needs","Tell the user you need them to do something", options: [
            option("why", "Why you need it"),
            option("step", "One step for the user", repeats: true),
            option("command", "A command to copy, or - for stdin", repeats: true),
            option("link", "A URL to open", repeats: true),
            option("done", "The label of the Done button"),
            option("answer", "Another way it can end", repeats: true),
            flag("wait", "Wait until the item is done or declined"),
            option("timeout", "Seconds to wait, with --wait"),
            session,
        ], subcommands: [
            command("list", "The open items", options: [flag("json", "Print them as JSON")]),
            command("resolve", "Clear an item once it is done", argument: .needsID),
        ], argument: .text),
        command("check", "Run only the auto mode risk check", options: [action, reason, permitCommand]),
        command("keys", "Show the shortcuts in effect"),
        command("settings", "Open the settings window"),
        command("approvals", "Open the list of standing approvals"),
        command("history", "Open the history of finished requests in the menu bar", options: [
            flag("missed", "Only timeouts and secrets to enter later"),
            flag("json", "Print them as a JSON array"),
        ]),
        command("pause", "Time out requests at once while you are away", options: [
            option("until", "Pause until this local time, as HH:MM"),
            flag("until-back", "Pause until the next keyboard or mouse input, after 1 minute"),
        ], argument: .text),
        command("resume", "End a pause now"),
        command("hooks", "Ask in stew when an agent blocks a call or asks for approval", subcommands: [
            command("install", "Add the hooks to Claude Code or Codex", options: [agentOption]),
            command("uninstall", "Remove the hooks", options: [agentOption]),
            command("status", "Show whether the hooks are installed", options: [agentOption]),
        ]),
        command("hook", "The hook commands Claude Code and Codex run", subcommands: [
            command("denied", "PermissionDenied hook", options: [hookAgentOption]),
            command("pre", "PreToolUse hook", options: [hookAgentOption]),
            command("question", "AskUserQuestion hook", options: [hookAgentOption]),
            command("permission", "PermissionRequest hook", options: [hookAgentOption]),
            command("stop", "Stop hook", options: [hookAgentOption]),
            command("prompt", "UserPromptSubmit hook", options: [hookAgentOption]),
        ], hidden: true),
        command("stop", "Stop the daemon"),
        command("daemon", "Run the daemon", hidden: true),
        command("version", "Print the version and build"),
        command("update", "Install the latest version now", options: [flag("check", "Only report whether there is one")]),
        command("setup", "Set up the daemon, skill and shell completion for this Stew.app", options: [
            flag("with-hooks", "Also add the agent hooks"),
            agentOption,
            flag("no-skill", "Skip the agent skill"),
            flag("no-completions", "Skip shell completion"),
            option("bin-dir", "Where to put the stew link", value: .directory),
        ]),
        command("uninstall", "Remove stew, keeping ~/.config/stew", options: [
            option("bin-dir", "Where the stew link is", value: .directory),
            option("app-dir", "Where Stew.app is", value: .directory),
            flag("keep-app", "Leave Stew.app in place"),
        ]),
        command("completions", "Print or install shell completion", subcommands: [
            command("fish", "Print the fish script"),
            command("zsh", "Print the zsh script"),
            command("bash", "Print the bash script"),
            command("install", "Install the fish and zsh scripts"),
            command("uninstall", "Remove the installed scripts"),
        ]),
    ])

    private static let action = option("action", "What you want to do")
    private static let reason = option("reason", "Why you want to do it")
    private static let permitCommand = option("command", "The exact command, or - for stdin")
    private static let session = option("session", "Label for the panel")
    private static let timeout = option("timeout", "Seconds to answer once on screen, 0 for no limit")

    private static func command(
        _ name: String,
        _ summary: String,
        options: [CompletionOption] = [],
        subcommands: [CompletionCommand] = [],
        argument: CompletionValue? = nil,
        hidden: Bool = false
    ) -> CompletionCommand {
        CompletionCommand(name: name, summary: summary, options: options, subcommands: subcommands, argument: argument, hidden: hidden)
    }

    private static func option(_ name: String, _ summary: String, value: CompletionValue = .text, repeats: Bool = false) -> CompletionOption {
        CompletionOption(name: name, summary: summary, value: value, repeats: repeats)
    }

    private static func flag(_ name: String, _ summary: String) -> CompletionOption {
        CompletionOption(name: name, summary: summary, value: nil, repeats: false)
    }

    /// `--agent` of `stew hooks` and `stew setup`.
    private static let agentOption = option("agent", "Which agent's hooks: claude (default), codex or all", value: .choices(["claude", "codex", "all"]))

    /// `--agent` of the hook commands: the agent that runs them.
    private static let hookAgentOption = option("agent", "The agent that runs the hook", value: .choices(["claude", "codex"]))
}

/// Compares the usage text with the command table. The usage text documents a command
/// on a line that starts with `  stew `; the words after `stew` up to the first option,
/// placeholder or description are its path (`a|b` names alternatives), and every
/// `--option` on that line and the indented lines under it belongs to it. `[common]`
/// adds the options listed under COMMON.
public enum UsageDrift {
    struct Entry {
        var path: [String]
        var options: Set<String>
    }

    /// One sentence per mismatch; empty when the two agree.
    public static func problems(usage: String, root: CompletionCommand) -> [String] {
        let entries = parse(usage)
        var problems: [String] = []

        for entry in entries {
            guard let chain = chain(for: entry.path, in: root) else {
                problems.append("`stew \(entry.path.joined(separator: " "))` is in the usage text but not in the command table")
                continue
            }
            let known = Set(chain.flatMap { $0.options.map(\.name) })
            for option in entry.options.sorted() where !known.contains(option) {
                problems.append("--\(option) of `stew \(entry.path.joined(separator: " "))` is in the usage text but not in the command table")
            }
        }

        func visit(_ command: CompletionCommand, path: [String]) {
            let documenting = entries.filter { $0.path.starts(with: path) }
            if !path.isEmpty, documenting.isEmpty {
                problems.append("`stew \(path.joined(separator: " "))` is in the command table but not in the usage text")
            }
            let documented = Set(documenting.flatMap(\.options))
            for option in command.options where !documented.contains(option.name) {
                let name = path.isEmpty ? "stew" : "stew \(path.joined(separator: " "))"
                problems.append("--\(option.name) of `\(name)` is in the command table but not in the usage text")
            }
            for subcommand in command.subcommands {
                visit(subcommand, path: path + [subcommand.name])
            }
        }
        visit(root, path: [])
        return problems
    }

    /// The commands from `root` down to `path`, or nil when one is missing.
    private static func chain(for path: [String], in root: CompletionCommand) -> [CompletionCommand]? {
        var chain = [root]
        for name in path {
            guard let next = chain.last?.subcommand(name) else { return nil }
            chain.append(next)
        }
        return chain
    }

    static func parse(_ usage: String) -> [Entry] {
        let optionPattern = try! NSRegularExpression(pattern: "--([a-z][a-z0-9-]*)")
        func options(in text: String) -> Set<String> {
            let range = NSRange(text.startIndex..., in: text)
            return Set(optionPattern.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            })
        }

        var section = ""
        var common: Set<String> = []
        var entries: [(paths: [[String]], options: Set<String>, takesCommon: Bool)] = []
        for line in usage.components(separatedBy: "\n") {
            if let first = line.first, first != " " {
                section = line
                continue
            }
            if section == "COMMON" {
                // Only the option a line starts with; the description may name others.
                if line.hasPrefix("  --"), let name = line.split(separator: " ").first {
                    common.insert(String(name.dropFirst(2)))
                }
                continue
            }
            guard section == "USAGE" else { continue }
            if line.hasPrefix("  stew ") {
                let synopsis = line.dropFirst(2).components(separatedBy: "  ").first ?? ""
                var paths: [[String]] = [[]]
                for word in synopsis.split(separator: " ").dropFirst() {
                    guard word.allSatisfy({ $0.isLowercase || $0 == "|" }), word.first?.isLowercase == true else { break }
                    let alternatives = word.split(separator: "|").map(String.init)
                    paths = paths.flatMap { path in alternatives.map { path + [$0] } }
                }
                entries.append((paths, options(in: line), synopsis.contains("[common]")))
            } else if line.hasPrefix("    "), !entries.isEmpty {
                entries[entries.count - 1].options.formUnion(options(in: line))
            }
        }
        return entries.flatMap { entry in
            entry.paths.map { Entry(path: $0, options: entry.takesCommon ? entry.options.union(common) : entry.options) }
        }
    }
}

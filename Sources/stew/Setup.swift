import Foundation
import StewCore

/// `stew setup`: the per-user part of an install, for a Stew.app that is already in
/// place, wherever that is. The install script runs it after it puts the app in
/// `~/Applications`; the Homebrew cask runs it from its postflight for `/Applications`.
/// Safe to run again: each step leaves what is already right as it is.
///
/// When the Homebrew cask installed the app (see `InstallLocation.isHomebrewCask`),
/// Homebrew links the command and the shell completion scripts itself, so setup adds no
/// `stew` link and no completion files, and removes the completion files an earlier
/// install from the script wrote. It touches an agent's hook file (`~/.claude/settings.json`,
/// `~/.codex/hooks.json`) only with `--with-hooks`, for the agents `--agent` names.
enum Setup {
    struct Options {
        var withHooks = false
        /// The agents `withHooks` installs hooks for: Claude Code unless `--agent` says.
        var hookAgents: [CodingAgent] = [.claudeCode]
        var withSkill = true
        var withCompletions = true
        var binDirectory = Paths.home + "/.local/bin"
    }

    static func run(_ options: Options) -> Int32 {
        guard let app = AppVersion.appBundle(forExecutable: Paths.executable) else {
            fail("this stew is not inside Stew.app. Install Stew.app first (./install.sh builds one from source).")
            return 1
        }
        let tool = InstallLocation.executable(inApp: app)
        let homebrew = InstallLocation.isHomebrewCask(
            app: app,
            prefixes: InstallLocation.homebrewPrefixes(environment: ProcessInfo.processInfo.environment),
            directoryExists: directoryExists,
            resolve: resolvedPath
        )
        let version = AppVersion.installed(at: app) ?? AppVersion.running
        step("Setting up stew \(version.version) in \((app as NSString).deletingLastPathComponent)\(homebrew ? " (installed by Homebrew)" : "")")
        var failures = 0

        let domain = "gui/\(getuid())"
        Launchctl.run(["bootout", "\(domain)/\(Paths.launchAgentLabel)"])

        linkCommand(tool: tool, binDirectory: options.binDirectory, homebrewProvidesCommand: homebrew, &failures)

        step("Starting the daemon (LaunchAgent \(Paths.launchAgentLabel))")
        if !startDaemon(executable: tool, domain: domain) { failures += 1 }

        if options.withSkill {
            for agent in CodingAgent.allCases {
                installSkill(from: app, for: agent, &failures)
            }
        }

        if homebrew {
            // Homebrew links its own scripts; copies from an earlier install would shadow
            // them, or stand where Homebrew wants to put its link.
            failures += CompletionInstaller.uninstall()
            note("Shell completion comes from Homebrew.")
        } else if options.withCompletions {
            step("Installing shell completion")
            if CompletionInstaller.install() != 0 { note("Shell completion was not installed completely; see above.") }
        }

        if options.withHooks {
            for agent in options.hookAgents {
                step("Installing the \(agent.productName) hooks")
                do {
                    try Hooks.install(agent: agent)
                } catch {
                    print("could not install the \(agent.productName) hooks: \(error)")
                    failures += 1
                }
            }
        }

        if failures == 0 {
            print("stew \(version) is set up.")
        } else {
            print("stew \(version) is set up, except for \(failures) item(s) listed above.")
        }
        return failures == 0 ? 0 : 1
    }

    /// The `stew` link in the bin folder. An install from before Stew.app put the binary
    /// itself there, and an earlier install may link another copy of the app: both become
    /// a link to this app, so the path that hooks and scripts call stays the same.
    private static func linkCommand(tool: String, binDirectory: String, homebrewProvidesCommand: Bool, _ failures: inout Int) {
        let link = binDirectory + "/stew"
        let fileManager = FileManager.default
        let existing: String? = (try? fileManager.attributesOfItem(atPath: link)) == nil ? nil : (resolvedPath(link) ?? "")
        let previousApp = existing.flatMap(AppVersion.appBundle(forExecutable:))
        switch CommandLinkPlan.choose(existing: existing, tool: resolvedPath(tool) ?? tool, homebrewProvidesCommand: homebrewProvidesCommand) {
        case .keep, .none:
            return
        case .create:
            break
        case .replace:
            if let previousApp {
                note("Pointing \(link) at this app instead of \(previousApp).")
            } else if existing == "" {
                note("Replacing the broken link at \(link).")
            } else {
                note("Replacing the old binary at \(link) with a link into Stew.app.")
            }
            do {
                try fileManager.removeItem(atPath: link)
            } catch {
                print("could not replace \(link): \(error.localizedDescription)")
                failures += 1
                return
            }
        }
        do {
            try fileManager.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: link, withDestinationPath: tool)
            note("\(link) -> \(tool)")
        } catch {
            print("could not link \(link): \(error.localizedDescription)")
            failures += 1
        }
        if let previousApp, homebrewProvidesCommand, fileManager.fileExists(atPath: previousApp) {
            note("The copy at \(previousApp) is no longer used. Remove it with: rm -rf \"\(previousApp)\"")
        }
    }

    /// Writes the LaunchAgent and starts it. launchd can take a moment to let go of the
    /// job that was just stopped, so bootstrap is retried for up to five seconds.
    private static func startDaemon(executable: String, domain: String) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(atPath: (Paths.launchAgent as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: Paths.home + "/Library/Logs", withIntermediateDirectories: true)
            let data = try LaunchAgentPlist.data(label: Paths.launchAgentLabel, executable: executable, logPath: Paths.home + "/Library/Logs/stew.log")
            try data.write(to: URL(fileURLWithPath: Paths.launchAgent), options: .atomic)
        } catch {
            print("could not write \(Paths.launchAgent): \(error.localizedDescription)")
            return false
        }
        for attempt in 1...10 {
            if Launchctl.run(["bootstrap", domain, Paths.launchAgent]) == 0 { return true }
            if attempt < 10 { usleep(500_000) }
        }
        print("launchctl could not start \(Paths.launchAgent). Try: launchctl bootstrap \(domain) \(Paths.launchAgent)")
        return false
    }

    /// The folder an agent reads the stew skill from, and the folder whose presence says
    /// the agent is installed. Codex reads user skills from ~/.agents/skills.
    static func skillLocation(for agent: CodingAgent) -> (agentFolder: String, displayFolder: String, skillFolder: String) {
        switch agent {
        case .claudeCode:
            (Paths.home + "/.claude", "~/.claude", Paths.home + "/.claude/skills/stew")
        case .codex:
            (Hooks.codexHome, SessionResolver.abbreviate(Hooks.codexHome, home: Paths.home), Paths.home + "/.agents/skills/stew")
        }
    }

    /// The skill goes only to an agent that is installed: one whose folder exists.
    private static func installSkill(from app: String, for agent: CodingAgent, _ failures: inout Int) {
        let location = skillLocation(for: agent)
        guard directoryExists(location.agentFolder) else {
            note("No \(location.displayFolder) folder, so the \(agent.productName) skill was skipped.")
            return
        }
        let source = app + "/Contents/Resources/skill/SKILL.md"
        let folder = location.skillFolder
        let fileManager = FileManager.default
        do {
            guard let skill = fileManager.contents(atPath: source) else { throw SetupError("\(source) is missing") }
            try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try skill.write(to: URL(fileURLWithPath: folder + "/SKILL.md"), options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder + "/SKILL.md")
            step("Installed the \(agent.productName) skill in \(SessionResolver.abbreviate(folder, home: Paths.home))")
        } catch {
            print("could not install the \(agent.productName) skill: \(error)")
            failures += 1
        }
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The path with every symbolic link followed, or nil when nothing is there.
    static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func step(_ text: String) { print("==> \(text)") }
    private static func note(_ text: String) { print("    \(text)") }
    private static func fail(_ text: String) { FileHandle.standardError.write(Data("stew: \(text)\n".utf8)) }

    private struct SetupError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// launchctl for the installers. Tests set STEW_INSTALL_LAUNCHCTL_LOG, so the calls go
/// to that file instead and never stop or start the real daemon.
enum Launchctl {
    @discardableResult
    static func run(_ arguments: [String]) -> Int32 {
        if let logPath = ProcessInfo.processInfo.environment["STEW_INSTALL_LAUNCHCTL_LOG"] {
            let line = Data(("launchctl " + arguments.joined(separator: " ") + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: line)
            }
            return 0
        }
        return Client.run("/bin/launchctl", arguments)
    }
}

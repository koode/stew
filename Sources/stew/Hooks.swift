import Darwin
import Foundation
import StewCore

/// Grants on disk, shared by the hooks (short-lived processes) and the daemon.
enum GrantFile {
    static var path: String {
        ProcessInfo.processInfo.environment["STEW_GRANTS"] ?? Paths.supportDirectory + "/grants.json"
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: path) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Read, change and write the grants under an exclusive lock. Writes only on change.
    @discardableResult
    static func update<Result>(_ body: (inout [Grant]) throws -> Result) rethrows -> Result {
        let lockFD = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer {
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }
        let original = read()
        var grants = original
        let result = try body(&grants)
        if grants != original, let data = try? encoder.encode(grants) {
            FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        return result
    }

    static func read() -> [Grant] {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return [] }
        return (try? decoder.decode([Grant].self, from: data)) ?? []
    }
}

enum Hooks {
    /// Seconds Claude Code waits for the PermissionDenied hook, so for the user's answer.
    static let deniedTimeout = 1800

    static var installedExecutable: String {
        let installed = Paths.home + "/.local/bin/stew"
        return FileManager.default.isExecutableFile(atPath: installed) ? installed : Paths.executable
    }

    static var claudeSettingsPath: String {
        ProcessInfo.processInfo.environment["STEW_CLAUDE_USER_SETTINGS"] ?? Paths.home + "/.claude/settings.json"
    }

    /// Grants apply per project: the git root of the session folder, else the folder.
    static func projectRoot(for cwd: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "rev-parse", "--show-toplevel"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return cwd }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let root = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !root.isEmpty ? root : cwd
    }

    static func readHookInput() throws -> HookCall {
        try HookCall.parse(FileHandle.standardInput.readDataToEndOfFile())
    }

    /// PreToolUse: runs before every tool call, so it returns at once when there is nothing stored.
    static func pre() -> Never {
        guard GrantFile.exists else {
            // Drain the input so Claude Code never sees a closed pipe.
            _ = FileHandle.standardInput.readDataToEndOfFile()
            exit(0)
        }
        guard let call = try? readHookInput() else { exit(0) }
        let decision = GrantFile.update { grants in
            GrantBook.preToolUse(grants: &grants, call: call, projectRoot: { projectRoot(for: call.cwd) })
        }
        if let decision {
            print(HookOutput.preToolUse(decision))
        }
        exit(0)
    }

    /// PreToolUse on AskUserQuestion: ask in stew instead of the terminal when the
    /// session is unattended (or always, per config). Returns the answers as the tool's
    /// input, or a denial with a reason Claude can act on. If the daemon cannot be
    /// reached, it prints nothing and Claude Code asks in the terminal as usual.
    static func question() -> Never {
        do {
            let call = try readHookInput()
            let (config, _) = loadConfig()
            let attended = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ATTENDED"]
            guard call.toolName == "AskUserQuestion",
                  QuestionRouting.shouldRoute(mode: config.routeQuestions, attended: attended) else { exit(0) }
            let questionSet = try JSONDecoder().decode(QuestionSet.self, from: Data(call.key.utf8))
            try questionSet.validate()
            var session = SessionResolver.resolve(
                explicitName: nil,
                environment: ProcessInfo.processInfo.environment,
                cwd: call.cwd,
                home: Paths.home,
                readFile: { FileManager.default.contents(atPath: $0) }
            )
            if let sessionID = call.sessionID { session.id = sessionID }
            let response = Client.send(StewRequest(session: session, prompt: .question(questionSet), maxWait: Double(deniedTimeout - 20)))
            switch response.status {
            case .answered:
                if let output = HookOutput.answeringQuestions(inputJSON: call.key, answers: response.answers ?? [:]) {
                    print(output)
                }
            case .timeout:
                print(HookOutput.deny(reason: response.note ?? "The user did not answer in time. Continue with a safe choice that does not need this answer."))
            case .dismissed:
                print(HookOutput.deny(reason: "The user closed the question without answering. Continue with a safe choice that does not need this answer, or ask again later."))
            default:
                Log.append("hook question: \(response.error ?? response.status.rawValue); falling back to the terminal")
            }
        } catch {
            Log.append("hook question: \(error)")
        }
        exit(0)
    }

    /// PermissionDenied: auto mode blocked a call. Ask the user; on approval, store a
    /// one-shot grant for the identical retry and tell Claude it may retry.
    static func denied() -> Never {
        do {
            let call = try readHookInput()
            guard let reason = call.reason, BlockedCall.isRetryable(reason: reason) else { exit(0) }
            let root = projectRoot(for: call.cwd)
            let category = BlockedCall.category(fromReason: reason)

            let coveredByCategory = GrantFile.update { grants -> Bool in
                guard GrantBook.categoryGrant(grants: grants, toolName: call.toolName, category: category, projectRoot: root) != nil else { return false }
                grants.append(GrantBook.once(for: call))
                return true
            }
            if coveredByCategory {
                print(HookOutput.retry())
                exit(0)
            }

            let hardDeny = category.map { hardDenyNames(workingDirectory: root).contains($0) } ?? false
            let blocked = BlockedCall(
                toolName: call.toolName,
                category: category,
                reason: reason,
                hardDeny: hardDeny,
                projectRoot: root,
                suggestions: call.toolName == "Bash" ? CommandText.ruleSuggestions(for: call.command ?? "") : []
            )
            var session = SessionResolver.resolve(
                explicitName: nil,
                environment: ProcessInfo.processInfo.environment,
                cwd: call.cwd,
                home: Paths.home,
                readFile: { FileManager.default.contents(atPath: $0) }
            )
            if let sessionID = call.sessionID { session.id = sessionID }
            let permission = PermissionRequest(
                action: call.description ?? "Use the \(call.toolName) tool",
                command: call.toolName == "Bash" ? call.command : "\(call.toolName): \(call.summary)",
                reason: claudeReason(transcriptPath: call.transcriptPath),
                blocked: blocked
            )
            // The user's time limit comes from the config; maxWait keeps any extension
            // inside Claude Code's hook timeout.
            let request = StewRequest(session: session, prompt: .permission(permission), maxWait: Double(deniedTimeout - 20))
            let response = Client.send(request)
            let note = response.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            switch response.status {
            case .approved:
                try GrantFile.update { grants in
                    grants.append(GrantBook.once(for: call))
                    if let choice = response.grant {
                        try apply(choice, toolName: call.toolName, projectRoot: root, grants: &grants)
                    }
                }
                print(HookOutput.retry())
            case .denied where !note.isEmpty, .timeout where !note.isEmpty:
                // The retry gets denied again, this time with the user's note (or the
                // "did not respond in time" note) as the reason, so Claude can move on.
                GrantFile.update { $0.append(GrantBook.denyNote(for: call, note: note)) }
                print(HookOutput.retry())
            default:
                break
            }
        } catch {
            Log.append("hook denied: \(error)")
        }
        exit(0)
    }

    /// Always on a command pattern goes into the project's Claude Code allow list.
    /// Hour grants and category grants stay in stew's store.
    static func apply(_ choice: GrantChoice, toolName: String, projectRoot: String, grants: inout [Grant]) throws {
        if choice.writesClaudeRule {
            let rule = "Bash(\(choice.scope.value))"
            let settingsPath = projectRoot + "/.claude/settings.local.json"
            try FileManager.default.createDirectory(atPath: projectRoot + "/.claude", withIntermediateDirectories: true)
            let updated = try ClaudeSettings.addingAllowRule(rule, to: FileManager.default.contents(atPath: settingsPath))
            try updated.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            grants.append(Grant(kind: .claudeRule, toolName: "Bash", value: rule, projectRoot: projectRoot, settingsPath: settingsPath))
        } else if let standing = GrantBook.standing(choice, toolName: toolName, projectRoot: projectRoot) {
            grants.append(standing)
        }
    }

    /// Claude's last message before the call, which usually says why it wants it.
    static func claudeReason(transcriptPath: String?) -> String {
        guard let transcriptPath, let handle = FileHandle(forReadingAtPath: transcriptPath) else {
            return "Claude did not say why."
        }
        defer { try? handle.close() }
        let tailSize: UInt64 = 1_000_000
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailSize ? size - tailSize : 0)
        let data = handle.readDataToEndOfFile()
        return RiskCheck.lastAssistantText(transcript: data) ?? "Claude did not say why."
    }

    static func hardDenyNames(workingDirectory: String) -> Set<String> {
        guard let policy = try? RiskChecker.policyJSON(workingDirectory: workingDirectory) else { return [] }
        return BlockedCall.hardDenyNames(policyJSON: policy)
    }

    static func install() throws {
        let path = claudeSettingsPath
        let current = FileManager.default.contents(atPath: path)
        let updated = try ClaudeSettings.installingHooks(executable: installedExecutable, deniedTimeout: deniedTimeout, into: current)
        guard updated != current else { print("hooks already installed in \(path)"); return }
        if let current {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try current.write(to: URL(fileURLWithPath: "\(path).bak-stew-\(stamp)"))
        }
        try updated.write(to: URL(fileURLWithPath: path), options: .atomic)
        print("installed PermissionDenied and PreToolUse hooks in \(path)")
    }

    static func uninstall() throws {
        let path = claudeSettingsPath
        let current = FileManager.default.contents(atPath: path)
        guard let updated = try ClaudeSettings.removingHooks(executable: installedExecutable, from: current) else {
            print("no stew hooks in \(path)")
            return
        }
        if let current {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try current.write(to: URL(fileURLWithPath: "\(path).bak-stew-\(stamp)"))
        }
        try updated.write(to: URL(fileURLWithPath: path), options: .atomic)
        print("removed stew hooks from \(path)")
    }

    static func status() {
        let state = ClaudeSettings.hookState(executable: installedExecutable, in: FileManager.default.contents(atPath: claudeSettingsPath))
        let standing = GrantFile.read().filter { $0.isStanding && $0.isLive(at: Date()) }
        switch state {
        case .complete: print("hooks: installed in \(claudeSettingsPath)")
        case .partial: print("hooks: partly installed in \(claudeSettingsPath); run `stew hooks install` to update")
        case .none: print("hooks: not installed in \(claudeSettingsPath)")
        }
        print("standing approvals: \(standing.count) (stew approvals to manage)")
    }
}

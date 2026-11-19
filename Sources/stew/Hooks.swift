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

    /// Codex's user config layer: CODEX_HOME when set, else ~/.codex. STEW_CODEX_HOME
    /// points the tests at a folder of their own.
    static var codexHome: String {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["STEW_CODEX_HOME"], !override.isEmpty { return override }
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty { return codexHome }
        return Paths.home + "/.codex"
    }

    /// stew writes Codex hooks to hooks.json, not inline into config.toml: JSON it can
    /// edit safely, and config.toml stays the user's.
    static var codexHooksPath: String { codexHome + "/hooks.json" }
    static var codexConfigPath: String { codexHome + "/config.toml" }

    /// The file that holds an agent's user-level hooks.
    static func hookFilePath(for agent: CodingAgent) -> String {
        switch agent {
        case .claudeCode: claudeSettingsPath
        case .codex: codexHooksPath
        }
    }

    static func hookState(for agent: CodingAgent) -> HookInstallState {
        let data = FileManager.default.contents(atPath: hookFilePath(for: agent))
        return HookFile.state(of: agent.stewHooks(waitTimeout: deniedTimeout), executable: installedExecutable, in: data)
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

    /// PreToolUse: runs before every tool call, so it returns at once when there is nothing
    /// stored. Besides the grants, it hands Claude the late answers waiting for its session.
    static func pre() -> Never {
        let hasGrants = GrantFile.exists
        guard hasGrants || LateAnswerFile.exists else {
            // Drain the input so Claude Code never sees a closed pipe.
            _ = FileHandle.standardInput.readDataToEndOfFile()
            exit(0)
        }
        guard let call = try? readHookInput() else { exit(0) }
        let decision = hasGrants ? GrantFile.update { grants in
            GrantBook.preToolUse(grants: &grants, call: call, projectRoot: { projectRoot(for: call.cwd) })
        } : nil
        let late = LateAnswerFile.deliver(sessionID: call.sessionID, agentID: call.agentID, event: "PreToolUse")
        if let output = HookOutput.preToolUse(decision, additionalContext: LateWording.combined(late)) {
            print(output)
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
            session.agent = .claudeCode
            let request = StewRequest(
                session: session, prompt: .question(questionSet), maxWait: Double(deniedTimeout - 20),
                origin: RequestOrigin(agentID: call.agentID)
            )
            let response = Client.send(request)
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
            session.agent = .claudeCode
            let permission = PermissionRequest(
                action: call.blockedAction,
                command: call.blockedCommand,
                reason: claudeReason(transcriptPath: call.transcriptPath),
                blocked: blocked
            )
            // The user's time limit comes from the config; maxWait keeps any extension
            // inside Claude Code's hook timeout.
            // The origin lets a late approval store the one-shot grant for this exact call.
            let request = StewRequest(
                session: session, prompt: .permission(permission), maxWait: Double(deniedTimeout - 20),
                origin: RequestOrigin(agentID: call.agentID, toolName: call.toolName, callKey: call.key)
            )
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

    /// PermissionRequest: the agent is about to ask for approval, so ask in stew too.
    /// Approve allows the call; Deny refuses it with the user's note as the message the
    /// agent reads. A timeout, a closed panel or no daemon prints nothing: the agent's own
    /// prompt then decides, so stew keeps no late answer for it.
    ///
    /// Codex shows its prompt after the hook. Claude Code shows it at the same time and
    /// runs no hook once it is answered there or blocks the call after its time limit, so
    /// for Claude Code the hook follows the transcript and gives up as soon as the call
    /// has a result: the daemon then takes the request off the panel.
    static func permission(agent: CodingAgent) -> Never {
        do {
            let call = try readHookInput()
            var session = SessionResolver.resolve(
                explicitName: nil,
                environment: ProcessInfo.processInfo.environment,
                cwd: call.cwd,
                home: Paths.home,
                readFile: { FileManager.default.contents(atPath: $0) }
            )
            if let sessionID = call.sessionID { session.id = sessionID }
            session.agent = agent
            let hookLimit = Double(deniedTimeout - 20)
            let request: StewRequest
            switch agent {
            case .claudeCode:
                let permission = PermissionRequest(
                    action: call.blockedAction,
                    command: call.blockedCommand,
                    reason: claudeReason(transcriptPath: call.transcriptPath)
                )
                request = StewRequest(
                    session: session, prompt: .permission(permission),
                    maxWait: PermissionRequest.claudeTimeLimit(toolName: call.toolName, permissionMode: call.permissionMode, hookLimit: hookLimit),
                    origin: RequestOrigin(agentID: call.agentID, agentAsksOnTimeout: true)
                )
            case .codex:
                request = StewRequest(
                    session: session, prompt: .permission(PermissionRequest.approval(call, agent: agent)), maxWait: hookLimit,
                    origin: RequestOrigin(agentID: call.agentID, agentAsksOnTimeout: true)
                )
            }
            let response = agent == .claudeCode ? sendUnlessSettled(request, call: call) : Client.send(request)
            let note = response.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch response.status {
            case .approved:
                print(HookOutput.permissionRequest(allow: true))
            case .denied:
                print(HookOutput.permissionRequest(allow: false, message: note.isEmpty ? "The user denied this in stew." : "The user denied this in stew: \(note)"))
            case .error:
                Log.append("hook permission: \(response.error ?? "error"); \(agent.productName) asks in its own prompt")
            default:
                break
            }
        } catch {
            Log.append("hook permission: \(error)")
        }
        exit(0)
    }

    /// Sends the request, and exits without an answer once the transcript shows a result
    /// for the call: the user answered Claude Code's own prompt, or it ran out of time.
    /// Exiting closes the connection, which takes the request off the panel.
    static func sendUnlessSettled(_ request: StewRequest, call: HookCall) -> StewResponse {
        let answer = PendingResponse()
        Thread.detachNewThread { answer.finish(Client.send(request)) }
        var watch = TerminalAnswerWatch(call: call)
        while !answer.wait(seconds: 0.5) {
            if watch?.settled() == true {
                Log.append("hook permission: \(call.toolName) got its result in Claude Code's own prompt")
                exit(0)
            }
            if watch == nil { watch = TerminalAnswerWatch(call: call) }
        }
        return answer.response ?? StewResponse(status: .error, error: "no answer")
    }

    /// Ends a Stop hook. Codex treats a Stop hook's output as invalid unless it is JSON, so
    /// for Codex the hook prints an empty decision; Claude Code gets nothing, as before.
    static func endTurnHook(_ agent: CodingAgent) -> Never {
        if agent == .codex { print(HookOutput.noDecision) }
        exit(0)
    }

    /// Stop: when the agent's last message has a `needs input:` line, the session waits on
    /// the user, so show it as a needs item. When it has none, the session moved on and
    /// its earlier automatic item goes. It runs in the background (async in the hook
    /// entry), decides nothing and always exits 0, so it never holds up or fails the end
    /// of a turn.
    static func stop(agent: CodingAgent) -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = TurnHookInput.parse(data),
              // Codex's transcript format is not a stable interface, so only Claude Code's is read.
              let message = input.lastAssistantMessage ?? (agent == .claudeCode ? lastAssistantMessage(transcriptPath: input.transcriptPath) : nil) else { endTurnHook(agent) }
        guard let needs = NeedsParser.parse(message, agent: agent) else {
            resolveAutomatic(sessionID: input.sessionID, control: "moved-on")
            endTurnHook(agent)
        }
        let (config, _) = loadConfig()
        guard AutoNeeds.shouldCreate(mode: config.autoNeeds, attended: attended(agent)) else { endTurnHook(agent) }
        var session = SessionResolver.resolve(
            explicitName: nil,
            environment: ProcessInfo.processInfo.environment,
            cwd: input.cwd ?? FileManager.default.currentDirectoryPath,
            home: Paths.home,
            readFile: { FileManager.default.contents(atPath: $0) }
        )
        if let sessionID = input.sessionID { session.id = sessionID }
        session.agent = agent
        let response = Client.send(StewRequest(session: session, prompt: .needs(needs), wait: false))
        if response.status == .error {
            Log.append("hook stop: \(response.error ?? "error")")
        }
        endTurnHook(agent)
    }

    /// Whether someone is at the session's terminal, as `QuestionRouting` reads it. Only
    /// Claude Code says so; for Codex it is unknown, which counts as attended, the same as
    /// a Claude Code version without the variable.
    static func attended(_ agent: CodingAgent) -> String? {
        agent == .claudeCode ? ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ATTENDED"] : nil
    }

    /// Stop, in the foreground: when the user answered a timed-out request of this
    /// session later, the agent must not stop before it has read the answer, so the stop
    /// is blocked with the answer as the reason. With nothing waiting it decides nothing,
    /// so the agent stops as usual. Reads only late-answers.json, so it never holds up a
    /// turn.
    static func stopLate(agent: CodingAgent) -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard LateAnswerFile.exists, let input = TurnHookInput.parse(data) else { endTurnHook(agent) }
        let late = LateAnswerFile.deliver(sessionID: input.sessionID, agentID: input.agentID, event: "Stop")
        if let reason = LateWording.combined(late) {
            print(HookOutput.blockStop(reason: reason))
            exit(0)
        }
        endTurnHook(agent)
    }

    /// UserPromptSubmit: a new message to the session answers what it was waiting on, so
    /// its automatic needs items go, and late answers go into the message's context. Runs
    /// before every prompt, so it only reads needs.json and late-answers.json, and talks
    /// to the daemon only when that session has an open item.
    static func prompt() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let input = TurnHookInput.parse(data)
        // Output from code Claude runs in the background is not the user answering: the
        // session's needs items stay open, and late answers wait for a real prompt or the
        // next tool call.
        if input?.isCodeOutput == true { exit(0) }
        resolveAutomatic(sessionID: input?.sessionID, control: "answered")
        let late = LateAnswerFile.deliver(sessionID: input?.sessionID, agentID: input?.agentID, event: "UserPromptSubmit")
        if let context = LateWording.combined(late) {
            print(HookOutput.promptContext(context))
        }
        exit(0)
    }

    /// Ends the session's automatic items through the daemon. Reads needs.json first, so
    /// a hook that runs on every turn or prompt talks to the daemon only when there is
    /// something to end.
    static func resolveAutomatic(sessionID: String?, control: String) {
        guard let sessionID, FileManager.default.fileExists(atPath: NeedsStore.path),
              !NeedsBook.answeredBy(sessionID: sessionID, in: NeedsStore.readFile()).isEmpty else { return }
        if Client.sendControl("needs \(control) \(sessionID)") == nil {
            Log.append("hook: daemon not running; needs items for \(sessionID) stay open")
        }
    }

    /// The transcript can lag behind the turn, so this is only a fallback for a Claude
    /// Code version whose Stop input has no `last_assistant_message`.
    static func lastAssistantMessage(transcriptPath: String?) -> String? {
        guard let transcriptPath, let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        let tailSize: UInt64 = 1_000_000
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailSize ? size - tailSize : 0)
        return RiskCheck.lastAssistantText(transcript: handle.readDataToEndOfFile(), maxCharacters: 50_000)
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

    static func install(agent: CodingAgent = .claudeCode) throws {
        let path = hookFilePath(for: agent)
        let current = FileManager.default.contents(atPath: path)
        let updated = try HookFile.installing(agent.stewHooks(waitTimeout: deniedTimeout), executable: installedExecutable, into: current)
        guard updated != current else {
            print("hooks already installed in \(path)")
            if agent == .codex { printCodexNotes(trust: false) }
            return
        }
        if let current {
            try current.write(to: URL(fileURLWithPath: backupPath(for: path)))
        } else if agent == .codex {
            try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        }
        try updated.write(to: URL(fileURLWithPath: path), options: .atomic)
        switch agent {
        case .claudeCode:
            print("installed PermissionDenied, PreToolUse, Stop and UserPromptSubmit hooks in \(path)")
        case .codex:
            print("installed PermissionRequest, Stop and UserPromptSubmit hooks in \(path)")
            printCodexNotes(trust: true)
        }
    }

    static func uninstall(agent: CodingAgent = .claudeCode) throws {
        let path = hookFilePath(for: agent)
        let current = FileManager.default.contents(atPath: path)
        let events = Array(Set(agent.stewHooks(waitTimeout: deniedTimeout).map(\.event)))
        let removed = agent == .claudeCode
            ? try ClaudeSettings.removingHooks(executable: installedExecutable, from: current)
            : try HookFile.removing(events: events, executable: installedExecutable, from: current)
        guard let updated = removed else {
            print("no stew hooks in \(path)")
            return
        }
        if let current {
            try current.write(to: URL(fileURLWithPath: backupPath(for: path)))
        }
        try updated.write(to: URL(fileURLWithPath: path), options: .atomic)
        print("removed stew hooks from \(path)")
    }

    /// The copy written before stew changes an agent's hook file.
    static func backupPath(for path: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        return "\(path).bak-stew-\(stamp)"
    }

    /// Codex skips a new or changed hook until the user trusts it, and loads none while
    /// hooks are off in config.toml.
    static func printCodexNotes(trust: Bool) {
        if trust {
            print(codexTrustNote)
        }
        let config = (try? String(contentsOfFile: codexConfigPath, encoding: .utf8)) ?? ""
        if CodexConfig.hooksDisabled(toml: config) {
            print("hooks are off in \(codexConfigPath) ([features] hooks = false): Codex runs no hooks until you remove that line.")
        }
        if CodexConfig.hasInlineHooks(toml: config) {
            print("\(codexConfigPath) also defines hooks inline: Codex runs both and warns at startup.")
        }
    }

    static let codexTrustNote = "Codex runs them only after you trust them: open /hooks in Codex, review the stew hooks and trust them. Codex asks again whenever a hook changes, such as after stew moves."

    static func status(agents: [CodingAgent] = [.claudeCode]) {
        for agent in agents {
            let path = hookFilePath(for: agent)
            let label = agent == .claudeCode ? "hooks" : "\(agent.productName) hooks"
            let state = hookState(for: agent)
            switch state {
            case .complete: print("\(label): installed in \(path)")
            case .partial: print("\(label): partly installed in \(path); run `stew hooks install\(agent == .claudeCode ? "" : " --agent \(agent.rawValue)")` to update")
            case .none: print("\(label): not installed in \(path)")
            }
            if agent == .codex {
                if state != .none { print("  " + codexTrustNote) }
                printCodexNotes(trust: false)
            }
        }
        if agents.contains(.claudeCode) {
            let standing = GrantFile.read().filter { $0.isStanding && $0.isLive(at: Date()) }
            print("standing approvals: \(standing.count) (stew approvals to manage)")
        }
    }
}

/// The daemon's answer, from the thread that waits for it.
final class PendingResponse: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: StewResponse?

    var response: StewResponse? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func finish(_ response: StewResponse) {
        lock.lock()
        stored = response
        lock.unlock()
        done.signal()
    }

    /// True once the answer is in; false after `seconds` without it.
    func wait(seconds: Double) -> Bool {
        done.wait(timeout: .now() + seconds) == .success
    }
}

/// Follows the transcript that records a call, from the hook's start on.
struct TerminalAnswerWatch {
    private var watch: TranscriptWatch
    private var follower = LineFollower()
    private let handle: FileHandle

    /// Nil while the transcript does not exist, such as a subagent's before its first call.
    init?(call: HookCall) {
        guard let transcriptPath = call.transcriptPath,
              let handle = FileHandle(forReadingAtPath: TranscriptWatch.path(transcriptPath: transcriptPath, agentID: call.agentID)) else { return nil }
        self.handle = handle
        watch = TranscriptWatch(toolName: call.toolName, key: call.key)
        // The call itself is among the last entries; earlier ones only matter for an
        // identical call that already has its result.
        let tailSize: UInt64 = 2_000_000
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailSize ? size - tailSize : 0)
        _ = watch.read(follower.lines(in: handle.readDataToEndOfFile()))
        watch.follow()
    }

    /// True once the call got its result.
    mutating func settled() -> Bool {
        watch.read(follower.lines(in: handle.readDataToEndOfFile()))
    }
}

import Foundation
import StewCore

/// Runs the auto mode style check through `claude -p` or `codex exec`, with the user's
/// effective auto mode rules when Claude Code has them, else stew's default rules.
final class RiskChecker {
    private let config: StewConfig.ClassifierConfig
    private static let policyCacheLifetime: TimeInterval = 600
    private static let queue = DispatchQueue(label: "stew.risk", attributes: .concurrent)
    private static let policyLock = NSLock()
    private static var subscriptionVerifiedAt = Date.distantPast
    private static var codexLoginVerifiedAt = Date.distantPast

    init(config: StewConfig.ClassifierConfig) {
        self.config = config
    }

    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Calls back on the main queue for the daemon; any queue is fine for the CLI.
    func check(_ permission: PermissionRequest, session: SessionInfo, completion: @escaping (Result<RiskAssessment, Error>) -> Void) {
        let config = self.config
        Self.queue.async {
            let result = Result { try Self.runCheck(permission, session: session, config: config) }
            if Thread.isMainThread || !Self.mainLoopRunning {
                completion(result)
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    static var mainLoopRunning = false

    private static func runCheck(_ permission: PermissionRequest, session: SessionInfo, config: StewConfig.ClassifierConfig) throws -> RiskAssessment {
        let engines = RiskCheckBackend(configValue: config.backend).engines(for: session.codingAgent)
        var tools: [RiskCheckEngine: String] = [:]
        let chosen = RiskCheckBackend.choose(engines) { engine in
            do {
                tools[engine] = try usableTool(engine, config: config)
                return nil
            } catch {
                return "\(error)"
            }
        }
        switch chosen {
        case .success(let engine):
            let tool = tools[engine]!
            switch engine {
            case .claude: return try runClaudeCheck(permission, session: session, config: config, claude: tool)
            case .codex: return try runCodexCheck(permission, session: session, config: config, codex: tool)
            }
        case .failure(let error):
            throw CheckFailure(description: error.description)
        }
    }

    /// The tool's path when it is installed and logged in the way the check needs, or an
    /// error that names what is missing.
    private static func usableTool(_ engine: RiskCheckEngine, config: StewConfig.ClassifierConfig) throws -> String {
        switch engine {
        case .claude:
            guard let claude = Paths.claudeBinary(configured: config.claudePath) else {
                throw CheckFailure(description: "claude CLI not found; set classifier.claudePath")
            }
            try requireSubscription(claude: claude)
            return claude
        case .codex:
            guard let codex = Paths.codexBinary(configured: config.codexPath) else {
                throw CheckFailure(description: "codex CLI not found; set classifier.codexPath")
            }
            try requireCodexLogin(codex: codex)
            return codex
        }
    }

    private static func runClaudeCheck(
        _ permission: PermissionRequest, session: SessionInfo, config: StewConfig.ClassifierConfig, claude: String
    ) throws -> RiskAssessment {
        let workingDirectory = expand(session.cwd) ?? Paths.home
        let promptFile = try systemPromptFile(claude: claude, workingDirectory: workingDirectory)
        let recent = recentUserMessages(sessionID: session.id, limit: config.recentUserMessages)
        let input = try RiskCheck.input(
            for: permission, session: session, recentUserMessages: recent,
            gitStatus: gitStatus(workingDirectory: workingDirectory)
        )

        // Runs from the cache folder so no project CLAUDE.md is read, with no tools,
        // no settings sources (so no hooks) and no saved session.
        let output = try runProcess(
            claude,
            [
                "-p",
                "--model", config.model,
                "--tools", "",
                "--setting-sources", "",
                "--no-session-persistence",
                "--system-prompt-file", promptFile,
                "--json-schema", RiskCheck.schema,
                "--output-format", "json",
            ],
            stdin: Data(input.utf8),
            directory: Paths.cacheDirectory,
            timeout: config.timeoutSeconds
        )
        var assessment = try RiskCheck.parse(cliOutput: output)
        assessment.riskyPart = RiskCheck.riskyPart(assessment.riskyPart, in: permission.command)
        return assessment
    }

    /// The same check through `codex exec`: the same input and the same verdict shape, so
    /// the panel and the iPhone show it the same way.
    private static func runCodexCheck(
        _ permission: PermissionRequest, session: SessionInfo, config: StewConfig.ClassifierConfig, codex: String
    ) throws -> RiskAssessment {
        let workingDirectory = expand(session.cwd) ?? Paths.home
        // Claude Code's rules when it is there to give them, else stew's defaults.
        let claude = Paths.claudeBinary(configured: config.claudePath)
        let policy = claude.flatMap { try? policyJSON(workingDirectory: workingDirectory, claude: $0) }
            .map { String(decoding: $0, as: UTF8.self) } ?? RiskCheck.defaultPolicyJSON
        let instructions = try cacheFile(named: "codex-policy", contents: RiskCheck.systemPrompt(policyJSON: policy), suffix: "txt")
        let schema = try cacheFile(named: "risk-schema", contents: RiskCheck.schema, suffix: "json")
        let recent = recentUserMessages(sessionID: session.id, agent: session.codingAgent, limit: config.recentUserMessages)
        let input = try RiskCheck.input(
            for: permission, session: session, recentUserMessages: recent,
            gitStatus: gitStatus(workingDirectory: workingDirectory)
        )
        let outputPath = Paths.cacheDirectory + "/codex-verdict-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        // Runs from the cache folder, so no project AGENTS.md or config is read.
        let printed = try runProcess(
            codex,
            RiskCheck.codexArguments(model: config.codexModel, instructionsPath: instructions, schemaPath: schema, outputPath: outputPath),
            stdin: Data(input.utf8),
            directory: Paths.cacheDirectory,
            timeout: config.timeoutSeconds,
            environment: codexChildEnvironment()
        )
        // The final message goes to the output file and to stdout; the file holds it alone.
        let output = FileManager.default.contents(atPath: outputPath).flatMap { $0.isEmpty ? nil : $0 } ?? printed
        var assessment = try RiskCheck.parse(codexOutput: output)
        assessment.riskyPart = RiskCheck.riskyPart(assessment.riskyPart, in: permission.command)
        return assessment
    }

    /// A file in the cache folder named after its contents, so concurrent checks never
    /// race on one file and a changed prompt gets a new file.
    private static func cacheFile(named name: String, contents: String, suffix: String) throws -> String {
        let path = Paths.cacheDirectory + "/\(name)-\(stableHash(contents)).\(suffix)"
        if !FileManager.default.fileExists(atPath: path) {
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    /// The check must run on the user's ChatGPT plan, never on API billing: the child
    /// environment has no API key variables, and `codex login status` must agree.
    private static func requireCodexLogin(codex: String) throws {
        policyLock.lock()
        let verified = Date().timeIntervalSince(codexLoginVerifiedAt) < policyCacheLifetime
        policyLock.unlock()
        if verified { return }
        let result = try runProcessResult(
            codex, ["login", "status"], stdin: nil, directory: Paths.cacheDirectory, timeout: 20, environment: codexChildEnvironment()
        )
        let output = String(decoding: result.output + result.errors, as: UTF8.self)
        guard RiskCheck.codexUsesChatGPTLogin(exitStatus: result.status, output: output) else {
            throw CheckFailure(description: "codex is not logged in with ChatGPT; skipped to avoid API billing")
        }
        policyLock.lock()
        codexLoginVerifiedAt = Date()
        policyLock.unlock()
    }

    /// The uncommitted work in the call's folder, so the check can say what a command
    /// would lose. Nil outside a git repo or when git does not answer quickly.
    private static func gitStatus(workingDirectory: String) -> String? {
        // No optional locks: the agent may be using the repo at the same moment.
        guard let output = try? runProcess(
            "/usr/bin/git", ["--no-optional-locks", "status", "--porcelain=v1", "--branch", "--untracked-files=normal"],
            stdin: nil, directory: workingDirectory, timeout: 5
        ) else { return nil }
        return RiskCheck.gitStatus(porcelain: String(decoding: output, as: UTF8.self))
    }

    /// The check must run on the user's Claude plan, never on pay-per-token API billing.
    /// The child environment has no API key variables; this confirms the CLI agrees.
    private static func requireSubscription(claude: String) throws {
        policyLock.lock()
        let verified = Date().timeIntervalSince(subscriptionVerifiedAt) < policyCacheLifetime
        policyLock.unlock()
        if verified { return }
        let output = try runProcess(claude, ["auth", "status"], stdin: nil, directory: Paths.cacheDirectory, timeout: 20)
        let status = try? JSONSerialization.jsonObject(with: output) as? [String: Any]
        let method = status?["authMethod"] as? String
        guard status?["loggedIn"] as? Bool == true, method == "claude.ai" else {
            throw CheckFailure(description: "claude is not logged in with a Claude subscription (auth: \(method ?? "none")); skipped to avoid API billing")
        }
        policyLock.lock()
        subscriptionVerifiedAt = Date()
        policyLock.unlock()
    }

    private static func systemPromptFile(claude: String, workingDirectory: String) throws -> String {
        let policy = try policyJSON(workingDirectory: workingDirectory, claude: claude)
        let prompt = RiskCheck.systemPrompt(policyJSON: String(decoding: policy, as: UTF8.self))
        // One file per distinct prompt keeps concurrent checks from racing on a shared file.
        let path = Paths.cacheDirectory + "/policy-\(stableHash(prompt)).txt"
        if !FileManager.default.fileExists(atPath: path) {
            try prompt.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    /// Effective auto mode rules (`claude auto-mode config`). They depend on the project,
    /// so they are cached per folder in a file that short-lived hook processes share.
    static func policyJSON(workingDirectory: String, claude: String? = nil) throws -> Data {
        if let override = ProcessInfo.processInfo.environment["STEW_POLICY_FILE"] {
            guard let data = FileManager.default.contents(atPath: override) else {
                throw CheckFailure(description: "cannot read \(override)")
            }
            return data
        }
        let cacheFile = Paths.cacheDirectory + "/automode-\(stableHash(workingDirectory)).json"
        if let modified = (try? FileManager.default.attributesOfItem(atPath: cacheFile))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < policyCacheLifetime,
           let data = FileManager.default.contents(atPath: cacheFile) {
            return data
        }
        guard let claude = claude ?? Paths.claudeBinary(configured: nil) else {
            throw CheckFailure(description: "claude CLI not found")
        }
        let directory = FileManager.default.fileExists(atPath: workingDirectory) ? workingDirectory : Paths.home
        let policy = try runProcess(claude, ["auto-mode", "config"], stdin: nil, directory: directory, timeout: 30)
        guard (try? JSONSerialization.jsonObject(with: policy)) != nil else {
            throw CheckFailure(description: "`claude auto-mode config` did not return JSON")
        }
        try? policy.write(to: URL(fileURLWithPath: cacheFile), options: .atomic)
        return policy
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func expand(_ path: String?) -> String? {
        guard let path else { return nil }
        return path.hasPrefix("~") ? Paths.home + path.dropFirst() : path
    }

    /// The user's recent messages in the asking agent's session file.
    static func recentUserMessages(sessionID: String?, agent: CodingAgent, limit: Int) -> [String] {
        switch agent {
        case .claudeCode: return recentUserMessages(sessionID: sessionID, limit: limit)
        case .codex: return recentCodexUserMessages(sessionID: sessionID, limit: limit)
        }
    }

    /// Codex keeps sessions in `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl` under its
    /// home. Only the last few days are searched, newest first.
    static func recentCodexUserMessages(sessionID: String?, limit: Int) -> [String] {
        guard let sessionID, !sessionID.isEmpty, limit > 0 else { return [] }
        let sessions = Hooks.codexHome + "/sessions"
        let calendar = Calendar(identifier: .gregorian)
        let fileManager = FileManager.default
        for daysAgo in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = String(format: "%@/%04d/%02d/%02d", sessions, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder),
                  let name = names.first(where: { $0.hasSuffix("-\(sessionID).jsonl") }),
                  let data = tail(of: folder + "/" + name) else { continue }
            return RiskCheck.recentUserMessages(codexSession: data, limit: limit)
        }
        return []
    }

    /// The last 2 MB of a file, from the first whole line.
    private static func tail(of path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let tailSize: UInt64 = 2_000_000
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailSize ? size - tailSize : 0)
        var data = handle.readDataToEndOfFile()
        if size > tailSize, let firstNewline = data.firstIndex(of: 0x0A) {
            data = data[(firstNewline + 1)...]
        }
        return data
    }

    /// Reads the tail of the session transcript; transcripts can grow to hundreds of MB.
    static func recentUserMessages(sessionID: String?, limit: Int) -> [String] {
        guard let sessionID, limit > 0 else { return [] }
        let projects = Paths.home + "/.claude/projects"
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return [] }
        guard let transcript = folders.lazy
            .map({ "\(projects)/\($0)/\(sessionID).jsonl" })
            .first(where: { FileManager.default.fileExists(atPath: $0) }),
            let handle = FileHandle(forReadingAtPath: transcript) else { return [] }
        defer { try? handle.close() }
        let tailSize: UInt64 = 2_000_000
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailSize ? size - tailSize : 0)
        var data = handle.readDataToEndOfFile()
        if size > tailSize, let firstNewline = data.firstIndex(of: 0x0A) {
            data = data[(firstNewline + 1)...]
        }
        return RiskCheck.recentUserMessages(transcript: data, limit: limit)
    }

    private static func runProcess(
        _ tool: String, _ arguments: [String], stdin: Data?, directory: String, timeout: TimeInterval,
        environment: [String: String]? = nil
    ) throws -> Data {
        let result = try runProcessResult(tool, arguments, stdin: stdin, directory: directory, timeout: timeout, environment: environment)
        if result.output.isEmpty {
            let message = String(decoding: result.errors.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw CheckFailure(description: message.isEmpty ? "\(name) exited with \(result.status)" : message)
        }
        return result.output
    }

    struct ProcessResult {
        var status: Int32
        var output: Data
        var errors: Data
    }

    /// Runs a tool with no shell in between: each argument reaches it as it is.
    private static func runProcessResult(
        _ tool: String, _ arguments: [String], stdin: Data?, directory: String, timeout: TimeInterval,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment ?? childEnvironment()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
        }
        try? input.fileHandleForWriting.close()

        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Drain both pipes while waiting so a chatty child cannot block on a full pipe.
        var outputData = Data()
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outputData = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errorData = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        process.waitUntilExit()
        group.wait()
        timer.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw CheckFailure(description: "timed out after \(Int(timeout)) s")
        }
        return ProcessResult(status: process.terminationStatus, output: outputData, errors: errorData)
    }

    /// Variables that would switch `claude` from the subscription login to API billing.
    static let billingOverrides: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "AWS_BEARER_TOKEN_BEDROCK",
    ]

    /// The daemon may have been started from inside a Claude session; those variables
    /// must not leak into the nested `claude` run. API key variables are removed so the
    /// check always runs on the subscription login.
    private static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDECODE" || key == "CLAUDE_JOB_DIR" || key == "CLAUDE_PID")
                && !billingOverrides.contains(key)
        }
        let extraPath = [Paths.home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (extraPath + [environment["PATH"] ?? ""]).joined(separator: ":")
        return environment
    }

    /// Variables that would switch `codex` from the ChatGPT login to API billing or
    /// another endpoint.
    static let codexBillingOverrides: Set<String> = ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL"]

    /// Codex variables that are not about the session the daemon may have been started
    /// from: where Codex keeps its state and login, and its certificate bundle.
    static let codexKeptVariables: Set<String> = ["CODEX_HOME", "CODEX_SQLITE_HOME", "CODEX_CA_CERTIFICATE"]

    /// The Claude child environment without API keys or the variables of a Codex session
    /// the daemon may have started in, so the nested run is a session of its own.
    private static func codexChildEnvironment() -> [String: String] {
        childEnvironment().filter { key, _ in
            !codexBillingOverrides.contains(key) && !(key.hasPrefix("CODEX_") && !codexKeptVariables.contains(key))
        }
    }
}

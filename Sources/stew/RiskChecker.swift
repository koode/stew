import Foundation
import StewCore

/// Runs the auto mode style check through `claude -p`, with the user's effective auto mode rules.
final class RiskChecker {
    private let config: StewConfig.ClassifierConfig
    private static let policyCacheLifetime: TimeInterval = 600
    private static let queue = DispatchQueue(label: "stew.risk", attributes: .concurrent)
    private static let policyLock = NSLock()
    private static var subscriptionVerifiedAt = Date.distantPast

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
        guard let claude = Paths.claudeBinary(configured: config.claudePath) else {
            throw CheckFailure(description: "claude CLI not found; set classifier.claudePath")
        }
        try requireSubscription(claude: claude)
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

    private static func runProcess(_ tool: String, _ arguments: [String], stdin: Data?, directory: String, timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = childEnvironment()
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
        if outputData.isEmpty {
            let message = String(decoding: errorData.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CheckFailure(description: message.isEmpty ? "claude exited with \(process.terminationStatus)" : message)
        }
        return outputData
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
}

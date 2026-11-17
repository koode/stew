import Foundation

/// Works out which agent session is calling, from flags and the environment Claude Code
/// and Codex set for the commands they run.
public enum SessionResolver {
    public static func resolve(
        explicitName: String?,
        environment: [String: String],
        cwd: String,
        home: String,
        readFile: (String) -> Data?
    ) -> SessionInfo {
        let agent = CodingAgent.detect(environment: environment)
        let id = agent == .codex ? CodingAgent.codexSessionID(environment: environment) : environment["CLAUDE_CODE_SESSION_ID"]
        let displayCwd = abbreviate(cwd, home: home)
        let name = nonEmpty(explicitName)
            ?? nonEmpty(environment["STEW_SESSION"])
            ?? jobName(jobDir: environment["CLAUDE_JOB_DIR"], readFile: readFile)
            ?? projectName(cwd: cwd, home: home)
        return SessionInfo(name: name, id: id, cwd: displayCwd, agent: agent)
    }

    /// Background jobs record their `--name` in the job's state file.
    static func jobName(jobDir: String?, readFile: (String) -> Data?) -> String? {
        guard let jobDir, let data = readFile(jobDir + "/state.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flags = object["respawnFlags"] as? [String],
              let flagIndex = flags.firstIndex(of: "--name"),
              flags.indices.contains(flagIndex + 1) else { return nil }
        return nonEmpty(flags[flagIndex + 1])
    }

    static func projectName(cwd: String, home: String) -> String {
        if cwd == home { return "~" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    public static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

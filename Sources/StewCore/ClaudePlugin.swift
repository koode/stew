import Foundation

/// The Claude Code plugin in `plugin/`. Its `hooks/hooks.json` holds the hooks that
/// `stew hooks install` writes to settings.json, generated from the same list, with the
/// plugin's launcher in place of the path to stew. A test fails when the file in the
/// repository differs from what `hooksFile()` returns; `stew _plugin-hooks` prints it.
public enum ClaudePlugin {
    /// The command prefix in the plugin's hooks: a script in the plugin that runs the
    /// installed stew, or reads the hook input and exits 0 without output when there is
    /// none, so Claude Code goes on as if the hook were not there. Quoted, because the
    /// plugin's folder can contain spaces.
    public static let launcher = "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/stew"

    /// Set by the launcher for the stew it runs, so a hook knows it came from the plugin.
    public static let hookEnvironmentKey = "STEW_PLUGIN_HOOK"

    /// The plugin's hooks.json: the file shape Claude Code reads from a plugin, a `hooks`
    /// object around the event map, which is the shape settings.json has too.
    public static func hooksFile() throws -> Data {
        try HookFile.installing(CodingAgent.claudeCode.stewHooks(waitTimeout: CodingAgent.hookWaitTimeout), executable: launcher, into: nil)
    }

    /// A plugin hook steps aside when the user's Claude Code settings already run the
    /// same stew hook, so a user with both the plugin and `stew hooks install` gets each
    /// hook once. The settings win: the user installed them on purpose, and they keep
    /// working when the plugin is off. Any stew path counts, because an older install may
    /// call stew at another path than this one. `arguments` is what follows `hook`, such
    /// as "denied" or "stop-late".
    public static func settingsRunSameHook(arguments: String, settings: Data?) -> Bool {
        guard let hook = CodingAgent.claudeCode.stewHooks(waitTimeout: CodingAgent.hookWaitTimeout).first(where: { $0.arguments == arguments }),
              let settings,
              let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let events = object["hooks"] as? [String: Any] else { return false }
        let handlers = (events[hook.event] as? [[String: Any]] ?? []).flatMap { entry in entry["hooks"] as? [[String: Any]] ?? [] }
        let suffix = " hook " + arguments
        return handlers.contains { handler in
            guard let command = handler["command"] as? String, command.hasSuffix(suffix) else { return false }
            let executable = String(command.dropLast(suffix.count))
            return executable.hasPrefix("/") && (executable as NSString).lastPathComponent == "stew"
        }
    }

    /// The plugin's name, the part before "@" in Claude Code's `enabledPlugins` keys.
    public static let pluginName = "stew"

    /// Whether Claude Code's user settings turn the stew plugin on, from any marketplace
    /// (this repository's or a directory's). The plugin then brings the skill, so
    /// `stew setup` leaves out its own copy and Claude Code does not load the skill twice.
    public static func isEnabled(settings: Data?) -> Bool {
        guard let settings,
              let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let enabledPlugins = object["enabledPlugins"] as? [String: Any] else { return false }
        return enabledPlugins.contains { key, value in
            key.split(separator: "@", maxSplits: 1).first.map(String.init) == pluginName && (value as? Bool) == true
        }
    }
}

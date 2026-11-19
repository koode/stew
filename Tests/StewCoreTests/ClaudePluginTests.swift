import Foundation
import Testing
@testable import StewCore

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func repositoryFile(_ relativePath: String) throws -> Data {
    try Data(contentsOf: repository.appendingPathComponent(relativePath))
}

private func jsonObject(_ relativePath: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: repositoryFile(relativePath)) as? [String: Any])
}

/// Settings with stew's hooks as `stew hooks install` writes them, for `executable`.
private func installedSettings(executable: String) throws -> Data {
    try ClaudeSettings.installingHooks(executable: executable, deniedTimeout: CodingAgent.hookWaitTimeout, into: nil)
}

@Suite("Claude Code plugin")
struct ClaudePluginTests {
    @Test func hookFileIsGeneratedFromTheInstalledHooks() throws {
        let committed = try repositoryFile("plugin/hooks/hooks.json")
        let generated = try ClaudePlugin.hooksFile()
        #expect(committed == generated, "plugin/hooks/hooks.json is out of date. Run: swift run stew _plugin-hooks > plugin/hooks/hooks.json")
    }

    @Test func pluginHooksAreWhatHooksInstallWrites() throws {
        // The same file as settings.json after `stew hooks install`, with the plugin's
        // launcher where the path to stew is.
        let executable = "/Users/someone/.local/bin/stew"
        let settings = String(decoding: try installedSettings(executable: executable), as: UTF8.self)
        let escapedLauncher = ClaudePlugin.launcher.replacingOccurrences(of: "\"", with: "\\\"")
        let plugin = String(decoding: try repositoryFile("plugin/hooks/hooks.json"), as: UTF8.self)
        #expect(settings.replacingOccurrences(of: executable, with: escapedLauncher) == plugin)
        let wanted = CodingAgent.claudeCode.stewHooks(waitTimeout: CodingAgent.hookWaitTimeout)
        #expect(HookFile.state(of: wanted, executable: ClaudePlugin.launcher, in: try repositoryFile("plugin/hooks/hooks.json")) == .complete)
    }

    @Test func manifestVersionFollowsTheAppVersion() throws {
        let appVersion = String(decoding: try repositoryFile("VERSION"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = try jsonObject("plugin/.claude-plugin/plugin.json")
        #expect(manifest["version"] as? String == appVersion, "set \"version\" in plugin/.claude-plugin/plugin.json to the version in VERSION")
    }

    @Test func marketplaceListsThePlugin() throws {
        let marketplace = try jsonObject(".claude-plugin/marketplace.json")
        let manifest = try jsonObject("plugin/.claude-plugin/plugin.json")
        let entries = try #require(marketplace["plugins"] as? [[String: Any]])
        let entry = try #require(entries.first { $0["name"] as? String == manifest["name"] as? String })
        #expect(entry["source"] as? String == "./plugin")
    }

    @Test func pluginCarriesTheSkillTheAppInstalls() throws {
        let skill = String(decoding: try repositoryFile("plugin/skills/stew/SKILL.md"), as: UTF8.self)
        #expect(skill.hasPrefix("---\nname: stew\n"))
        let buildScript = String(decoding: try repositoryFile("scripts/build-app.sh"), as: UTF8.self)
        #expect(buildScript.contains("\"$project_root/plugin/skills/stew/SKILL.md\""), "Stew.app must ship the plugin's skill, so `stew setup` installs the same file")
    }

    @Test func pluginHookStepsAsideForTheSameHookInSettings() throws {
        let settings = try installedSettings(executable: "/Users/someone/.local/bin/stew")
        for hook in CodingAgent.claudeCode.stewHooks(waitTimeout: CodingAgent.hookWaitTimeout) {
            #expect(ClaudePlugin.settingsRunSameHook(arguments: hook.arguments, settings: settings), "\(hook.arguments)")
        }
    }

    @Test func anyStewPathInSettingsCounts() throws {
        let settings = try installedSettings(executable: "/Applications/Stew.app/Contents/MacOS/stew")
        #expect(ClaudePlugin.settingsRunSameHook(arguments: "denied", settings: settings))
    }

    @Test func pluginHookRunsWhenSettingsLackThatHook() throws {
        #expect(!ClaudePlugin.settingsRunSameHook(arguments: "denied", settings: nil))
        #expect(!ClaudePlugin.settingsRunSameHook(arguments: "denied", settings: Data("{}".utf8)))
        #expect(!ClaudePlugin.settingsRunSameHook(arguments: "denied", settings: Data("not json".utf8)))
        // An older install with only some of today's hooks: the plugin runs the others.
        let older = Data("""
        {"hooks":{"PermissionDenied":[{"matcher":"*","hooks":[{"type":"command","command":"/u/.local/bin/stew hook denied"}]}],
        "Stop":[{"hooks":[{"type":"command","command":"/u/.local/bin/stew hook stop-late"}]}]}}
        """.utf8)
        #expect(ClaudePlugin.settingsRunSameHook(arguments: "denied", settings: older))
        #expect(ClaudePlugin.settingsRunSameHook(arguments: "stop-late", settings: older))
        #expect(!ClaudePlugin.settingsRunSameHook(arguments: "stop", settings: older))
        #expect(!ClaudePlugin.settingsRunSameHook(arguments: "question", settings: older))
    }

    @Test func otherCommandsAreNotStew() throws {
        let settings = Data("""
        {"hooks":{"PermissionDenied":[{"matcher":"*","hooks":[
        {"type":"command","command":"/u/bin/notstew hook denied"},
        {"type":"command","command":"stew hook denied"},
        {"type":"command","command":"\\"${CLAUDE_PLUGIN_ROOT}\\"/scripts/stew hook denied"}]}],
        "Stop":[{"hooks":[{"type":"command","command":"/u/.local/bin/stew hook denied"}]}]}}
        """.utf8)
        // A command that only looks like stew's, or stew's command on another event,
        // leaves the plugin's hook running.
        #expect(!ClaudePlugin.settingsRunSameHook(arguments: "denied", settings: settings))
        #expect(!ClaudePlugin.settingsRunSameHook(arguments: "unknown", settings: try installedSettings(executable: "/u/stew")))
    }
}

/// The launcher script in plugin/scripts/stew, run with a home folder of its own.
@Suite("Claude Code plugin launcher")
struct ClaudePluginLauncherTests {
    struct Run {
        var status: Int32
        var output: String
    }

    static func run(home: URL, input: String) throws -> Run {
        let process = Process()
        process.executableURL = repository.appendingPathComponent("plugin/scripts/stew")
        process.arguments = ["hook", "pre"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        try process.run()
        standardInput.fileHandleForWriting.write(Data(input.utf8))
        try standardInput.fileHandleForWriting.close()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }

    static func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("stew-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func runsTheInstalledStewWithTheHookArguments() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binDirectory = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let fakeStew = binDirectory.appendingPathComponent("stew")
        try "#!/bin/sh\necho \"$* plugin=$STEW_PLUGIN_HOOK input=$(cat)\"\n".write(to: fakeStew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeStew.path)
        let result = try Self.run(home: home, input: "{\"session_id\":\"one\"}")
        #expect(result.status == 0)
        #expect(result.output == "hook pre plugin=1 input={\"session_id\":\"one\"}\n")
    }

    /// Only where no stew is installed in the places the launcher looks outside the home
    /// folder, such as on CI.
    static let noSystemStew = ["/opt/homebrew/bin/stew", "/usr/local/bin/stew", "/Applications/Stew.app/Contents/MacOS/stew"]
        .allSatisfy { !FileManager.default.fileExists(atPath: $0) }

    @Test(.enabled(if: noSystemStew)) func doesNothingWithoutStew() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try Self.run(home: home, input: String(repeating: "x", count: 200_000))
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }
}

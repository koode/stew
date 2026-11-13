import Foundation
import Testing
@testable import StewCore

/// The usage text from Sources/stew/main.swift. The executable target cannot be
/// imported, so the test reads the string literal from the source file.
private func realUsage() throws -> String {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: repository.appendingPathComponent("Sources/stew/main.swift"), encoding: .utf8)
    let opening = "let usage = \"\"\"\n"
    let start = try #require(source.range(of: opening))
    let end = try #require(source.range(of: "\n\"\"\"\n", range: start.upperBound..<source.endIndex))
    let usage = String(source[start.upperBound..<end.lowerBound])
    #expect(!usage.contains("\\("), "the test reads the literal as it is, so the usage text must stay free of interpolation")
    return usage
}

@Suite("Shell completion")
struct CompletionTests {
    @Test func usageTextAndCommandTableAgree() throws {
        let problems = UsageDrift.problems(usage: try realUsage(), root: CommandTable.root)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func usageParsingFindsEveryDocumentedCommand() throws {
        let paths = Set(UsageDrift.parse(try realUsage()).map { $0.path.joined(separator: " ") })
        for path in ["permit", "needs", "needs list", "needs resolve", "hooks install", "hooks status", "hook denied",
                     "history", "approvals", "completions fish", "completions install", "uninstall", "update"] {
            #expect(paths.contains(path), "usage parsing misses stew \(path)")
        }
    }

    @Test func driftIsReportedBothWays() {
        let usage = """
        USAGE
          stew greet NAME [--loud] [common]
              Say hello. --shout is louder.
          stew tools list|clean
          stew version       Print it (also --version).

        COMMON
          --session NAME     Label.
        """
        let root = CompletionCommand(name: "stew", summary: "", options: [
            CompletionOption(name: "version", summary: "", value: nil, repeats: false),
        ], subcommands: [
            CompletionCommand(name: "greet", summary: "", options: [
                CompletionOption(name: "loud", summary: "", value: nil, repeats: false),
                CompletionOption(name: "quiet", summary: "", value: nil, repeats: false),
            ], subcommands: [], argument: .text, hidden: false),
            CompletionCommand(name: "tools", summary: "", options: [], subcommands: [
                CompletionCommand(name: "list", summary: "", options: [], subcommands: [], argument: nil, hidden: false),
            ], argument: nil, hidden: false),
            CompletionCommand(name: "version", summary: "", options: [], subcommands: [], argument: nil, hidden: false),
            CompletionCommand(name: "extra", summary: "", options: [], subcommands: [], argument: nil, hidden: true),
        ], argument: nil, hidden: false)
        let problems = Set(UsageDrift.problems(usage: usage, root: root))
        #expect(problems == [
            "--shout of `stew greet` is in the usage text but not in the command table",
            "--session of `stew greet` is in the usage text but not in the command table",
            "`stew tools clean` is in the usage text but not in the command table",
            "--quiet of `stew greet` is in the command table but not in the usage text",
            "`stew extra` is in the command table but not in the usage text",
        ])
    }

    @Test func scriptsOfferNoInternalOrHiddenCommands() {
        let fish = CompletionScript.script(for: .fish)
        let zsh = CompletionScript.script(for: .zsh)
        let bash = CompletionScript.script(for: .bash)
        #expect(!fish.contains("-a _") && !zsh.contains("'_control") && !bash.contains("_sign-update"))
        #expect(!fish.contains("-n '__stew_typed' -a hook "))
        #expect(!fish.contains("-n '__stew_typed' -a daemon "))
        #expect(fish.contains("-n '__stew_typed hook' -a denied"), "a hidden command still completes once typed")
        #expect(fish.contains("-n '__stew_typed' -a needs "))
        #expect(fish.contains("-n '__stew_after needs -- list resolve' -l step -x"))
        #expect(fish.contains("-l file -r -F"))
        #expect(zsh.hasPrefix("#compdef stew\n"))
        #expect(zsh.contains("'*--step=[One step for the user]:step: '"))
        #expect(zsh.contains("'--level=[How the panel looks]:level:(info success warning error)'"))
        #expect(zsh.contains("'1:id:_stew_needs_ids'"))
        #expect(bash.hasSuffix("complete -F _stew stew\n"))
    }

    @Test func generatedScriptsAreRecognised() {
        for shell in CompletionShell.allCases {
            #expect(CompletionScript.isGenerated(CompletionScript.script(for: shell)), "\(shell)")
        }
        #expect(!CompletionScript.isGenerated("#compdef stew\n_arguments '--help'\n"))
        #expect(!CompletionScript.isGenerated(""))
    }

    @Test func zshPrefersAPersonalFolderOnFpath() {
        let choice = ZshCompletionPlacement.choose(
            fpath: ["/opt/homebrew/share/zsh/site-functions", "/Users/test/.zfunc", "/usr/share/zsh/5.9/functions"],
            home: "/Users/test",
            isWritableDirectory: { _ in true }
        )
        #expect(choice == .init(directory: "/Users/test/.zfunc", onFpath: true))
    }

    @Test func zshUsesAWritableSiteFunctionsFolder() {
        let writable: Set<String> = ["/opt/homebrew/share/zsh/site-functions"]
        let choice = ZshCompletionPlacement.choose(
            fpath: ["/usr/local/share/zsh/site-functions", "/opt/homebrew/Cellar/zsh/5.9/share/zsh/site-functions",
                    "/opt/homebrew/share/zsh/site-functions/", "/usr/share/zsh/site-functions"],
            home: "/Users/test",
            isWritableDirectory: writable.contains
        )
        #expect(choice == .init(directory: "/opt/homebrew/share/zsh/site-functions", onFpath: true))
    }

    @Test func zshSkipsVersionedAndSystemFolders() {
        let choice = ZshCompletionPlacement.choose(
            fpath: ["/opt/homebrew/Cellar/zsh/5.9/share/zsh/site-functions", "/usr/share/zsh/site-functions"],
            home: "/Users/test",
            isWritableDirectory: { _ in true }
        )
        #expect(choice == .init(directory: "/Users/test/.zsh/completions", onFpath: false))
    }

    @Test func zshFallsBackWhenTheFpathIsUnknown() {
        let choice = ZshCompletionPlacement.choose(fpath: nil, home: "/Users/test", isWritableDirectory: { _ in true })
        #expect(choice == .init(directory: "/Users/test/.zsh/completions", onFpath: false))
    }
}

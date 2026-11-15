import Foundation
import Testing
@testable import StewCore

private func sampleQuestions(multiSecond: Bool = false) -> [Question] {
    [
        Question(question: "Which database?", header: "DB", options: [
            QuestionOption(label: "Postgres", description: "Relational", preview: "CREATE TABLE ..."),
            QuestionOption(label: "SQLite", description: "Embedded"),
        ]),
        Question(question: "Which extras?", header: "Extras", options: [
            QuestionOption(label: "Auth", description: "Login"),
            QuestionOption(label: "Billing", description: "Stripe"),
            QuestionOption(label: "Search", description: "Full text"),
        ], multiSelect: multiSecond),
    ]
}

@Suite struct QuestionFlowTests {
    @Test func singleSelectAdvancesThenCompletes() {
        var flow = QuestionFlow(questions: sampleQuestions())
        #expect(flow.choose(1) == .advanced)
        #expect(flow.index == 1)
        #expect(flow.choose(2) == .complete)
        #expect(flow.answers() == ["Which database?": "SQLite", "Which extras?": "Search"])
    }

    @Test func outOfRangeOptionIsIgnored() {
        var flow = QuestionFlow(questions: sampleQuestions())
        #expect(flow.choose(3) == .stay)
        #expect(flow.answers().isEmpty)
    }

    @Test func multiSelectTogglesAndNeedsSubmit() {
        var flow = QuestionFlow(questions: sampleQuestions(multiSecond: true))
        flow.go(to: 1)
        #expect(flow.submitCurrent() == .missing(0))
        #expect(flow.index == 0)
        flow.go(to: 1)
        #expect(flow.choose(2) == .stay)
        #expect(flow.choose(0) == .stay)
        #expect(flow.choose(2) == .stay)
        #expect(flow.choose(1) == .stay)
        #expect(flow.submitCurrent() == .missing(0))
        #expect(flow.index == 0)
        #expect(flow.choose(0) == .complete)
        #expect(flow.answers()["Which extras?"] == "Auth, Billing")
    }

    @Test func otherReplacesSingleChoiceAndAddsToMulti() {
        var flow = QuestionFlow(questions: sampleQuestions(multiSecond: true))
        _ = flow.choose(0)
        flow.previous()
        #expect(flow.answerOther("  DuckDB ") == .advanced)
        #expect(flow.answers()["Which database?"] == "DuckDB")
        _ = flow.choose(1)
        #expect(flow.answerOther("Webhooks") == .complete)
        #expect(flow.answers()["Which extras?"] == "Billing, Webhooks")
    }

    @Test func emptyOtherDoesNotAnswer() {
        var flow = QuestionFlow(questions: sampleQuestions())
        #expect(flow.answerOther("   ") == .missing(0))
        #expect(!flow.isAnswered(0))
    }

    /// The set from the bug report: a single select, then a multi select, answered in
    /// order and sent with Submit on the last question.
    static let reportedSet = [
        Question(question: "Which maximum line width should oxfmt use?", header: "", options: [
            QuestionOption(label: "160 (Recommended)", description: ""),
            QuestionOption(label: "180", description: ""),
            QuestionOption(label: "120", description: ""),
        ]),
        Question(question: "Which shared versions should Claude build?", header: "", options: [
            QuestionOption(label: "e2e GraphQL helper", description: ""),
            QuestionOption(label: "One upload function", description: ""),
            QuestionOption(label: "One useNow hook", description: ""),
        ], multiSelect: true),
    ]

    @Test func reportedSetCompletesOnSubmit() {
        var flow = QuestionFlow(questions: Self.reportedSet)
        #expect(flow.choose(0) == .advanced)
        #expect(flow.index == 1)
        #expect(flow.choose(0) == .stay)
        #expect(flow.choose(2) == .stay)
        #expect(flow.submitCurrent() == .complete)
        #expect(flow.answers() == [
            "Which maximum line width should oxfmt use?": "160 (Recommended)",
            "Which shared versions should Claude build?": "e2e GraphQL helper, One useNow hook",
        ])
    }

    @Test func submitWithAnOpenQuestionGoesThereAndSaysSo() {
        var flow = QuestionFlow(questions: Self.reportedSet)
        flow.go(to: 1)
        _ = flow.choose(1)
        #expect(flow.submitCurrent() == .missing(0))
        #expect(flow.index == 0)
        #expect(flow.missingMessage(0) == "Q1 has no answer yet.")
        #expect(flow.firstUnanswered == 0)
        _ = flow.choose(1)
        #expect(flow.firstUnanswered == nil)
    }

    @Test func confirmOnAnUnansweredQuestionSaysSo() {
        var flow = QuestionFlow(questions: sampleQuestions(multiSecond: true))
        _ = flow.choose(0)
        #expect(flow.submitCurrent() == .missing(1))
        #expect(flow.missingMessage(1) == "Extras has no answer yet.")
        let single = QuestionFlow(questions: [sampleQuestions(multiSecond: true)[1]])
        #expect(single.missingMessage(0) == "Choose at least one option, or type an answer under Other.")
        #expect(QuestionFlow(questions: [sampleQuestions()[0]]).missingMessage(0) == "Choose an option, or type an answer under Other.")
    }

    @Test func confirmOnAnAnsweredQuestionMovesOn() {
        var flow = QuestionFlow(questions: sampleQuestions(multiSecond: true) + [Question(question: "Why?", header: "", options: [
            QuestionOption(label: "Speed", description: ""),
        ])])
        flow.go(to: 1)
        _ = flow.choose(0)
        #expect(flow.submitCurrent() == .advanced)
        #expect(flow.index == 2)
    }

    @Test func annotationsCarryChosenPreview() {
        var flow = QuestionFlow(questions: sampleQuestions())
        _ = flow.choose(0)
        _ = flow.choose(0)
        #expect(flow.annotations() == ["Which database?": QuestionAnnotation(preview: "CREATE TABLE ...")])
    }

    @Test func navigationClamps() {
        var flow = QuestionFlow(questions: sampleQuestions())
        flow.previous()
        #expect(flow.index == 0)
        flow.next(); flow.next()
        #expect(flow.index == 1)
    }
}

@Suite struct ValidationTests {
    @Test func acceptsAskUserQuestionInput() throws {
        let json = """
        {"questions":[{"question":"Pick one?","header":"Pick","multiSelect":false,
          "options":[{"label":"A","description":"first"},{"label":"B","description":"second","preview":"b"}]}]}
        """
        let set = try JSONDecoder().decode(QuestionSet.self, from: Data(json.utf8))
        try set.validate()
        #expect(set.questions[0].options[1].preview == "b")
    }

    @Test func rejectsWrongCounts() {
        let one = QuestionSet(questions: [Question(question: "Q?", header: "Q", options: [QuestionOption(label: "A", description: "")])])
        #expect(throws: QuestionSet.ValidationError.self) { try one.validate() }
        #expect(throws: QuestionSet.ValidationError.self) { try QuestionSet(questions: []).validate() }
    }

    @Test func rejectsDuplicateLabels() {
        let set = QuestionSet(questions: [Question(question: "Q?", header: "Q", options: [
            QuestionOption(label: "A", description: ""), QuestionOption(label: "A", description: ""),
        ])])
        #expect(throws: QuestionSet.ValidationError.self) { try set.validate() }
    }
}

@Suite struct WireTests {
    @Test func requestRoundTripsForEveryKind() throws {
        let session = SessionInfo(name: "job", id: "abc-def", cwd: "~/x")
        let requests = [
            StewRequest(session: session, prompt: .permission(PermissionRequest(action: "Delete", command: "rm -rf x", reason: "stale")), timeout: 30),
            StewRequest(session: session, prompt: .notify(NotifyRequest(title: "Done", level: .success)), wait: false),
            StewRequest(session: session, prompt: .question(QuestionSet(questions: sampleQuestions()))),
        ]
        for request in requests {
            let line = try Wire.encode(request)
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A))
            #expect(try Wire.decode(StewRequest.self, line: line.dropLast()) == request)
        }
    }

    @Test func exitCodes() {
        #expect(StewResponse(status: .approved).exitCode == 0)
        #expect(StewResponse(status: .denied).exitCode == 1)
        #expect(StewResponse(status: .dismissed).exitCode == 2)
        #expect(StewResponse(status: .timeout).exitCode == 3)
    }
}

@Suite struct ShortcutTests {
    @Test func bareKeyJoinsChord() throws {
        let shortcut = try Shortcut.parse("y", chord: [.control, .option])
        #expect(shortcut.description == "⌃⌥Y")
    }

    @Test func fullSpecStandsAlone() throws {
        let shortcut = try Shortcut.parse("cmd+shift+return", chord: [.control, .option])
        #expect(shortcut == Shortcut(modifiers: [.command, .shift], key: .special(.return)))
        #expect(shortcut.description == "⇧⌘↩")
    }

    @Test func plainKeysAreRefused() {
        #expect(throws: Shortcut.ParseError.self) { try Shortcut.parse("y", chord: []) }
        #expect(throws: Shortcut.ParseError.self) { try Shortcut.parse("shift+y", chord: [.control]) }
        #expect(throws: Shortcut.ParseError.self) { try Shortcut.parse("hyper+y", chord: [.control]) }
    }

    @Test func defaultKeymapHasNoConflicts() throws {
        let keymap = try Keymap(config: StewConfig())
        #expect(keymap[.approve].description == "⌘↩")
        #expect(keymap[.deny].description == "⌘D")
        #expect(keymap[.dismiss].description == "⌘.")
        #expect(keymap[.dismissAll].description == "⇧⌘.")
        #expect(keymap[.next].description == "⌘]")
        #expect(keymap.options.map(\.description) == ["⌘1", "⌘2", "⌘3", "⌘4"])
        #expect(keymap[.approve].adding(keymap.hardDenyExtra).description == "⇧⌘↩")
    }

    @Test func approveAndSubmitMayShareAKey() throws {
        let keymap = try Keymap(config: StewConfig())
        #expect(keymap[.approve] == keymap[.submit])
    }

    @Test func conflictingConfigIsRejected() throws {
        let sameAsApprove = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"keys":{"deny":"return"}}"#.utf8))
        #expect(throws: Shortcut.ParseError.self) { try Keymap(config: sameAsApprove) }
        let sameAsOption = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"keys":{"next":"2"}}"#.utf8))
        #expect(throws: Shortcut.ParseError.self) { try Keymap(config: sameAsOption) }
        let sameAsHardDenyApprove = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"keys":{"deny":"cmd+shift+return"}}"#.utf8))
        #expect(throws: Shortcut.ParseError.self) { try Keymap(config: sameAsHardDenyApprove) }
    }

    @Test func partialConfigKeepsDefaults() throws {
        let config = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"chord":"ctrl+cmd","classifier":{"model":"sonnet"}}"#.utf8))
        let keymap = try Keymap(config: config)
        #expect(keymap[.deny].description == "⌃⌘D")
        #expect(config.armDelay == 0.5)
        #expect(config.classifier.model == "sonnet")
        #expect(config.classifier.enabled)
    }
}

@Suite struct SessionResolverTests {
    let home = "/Users/me"

    @Test func explicitNameWins() {
        let session = SessionResolver.resolve(explicitName: "deploy", environment: ["STEW_SESSION": "env"], cwd: "/Users/me/p/app", home: home) { _ in nil }
        #expect(session.name == "deploy")
        #expect(session.cwd == "~/p/app")
    }

    @Test func jobNameFromStateFile() {
        let state = #"{"respawnFlags":["--agent","claude","--name","tooling: notify"]}"#
        let environment = ["CLAUDE_JOB_DIR": "/jobs/1", "CLAUDE_CODE_SESSION_ID": "5b1f0c3a-ace5"]
        let session = SessionResolver.resolve(explicitName: nil, environment: environment, cwd: "/tmp", home: home) { path in
            path == "/jobs/1/state.json" ? Data(state.utf8) : nil
        }
        #expect(session.name == "tooling: notify")
        #expect(session.shortID == "5b1f0c3a")
    }

    @Test func fallsBackToFolderName() {
        let session = SessionResolver.resolve(explicitName: nil, environment: [:], cwd: "/Users/me/Projects/stew", home: home) { _ in nil }
        #expect(session.name == "stew")
        #expect(SessionResolver.resolve(explicitName: nil, environment: [:], cwd: home, home: home) { _ in nil }.name == "~")
    }
}

@Suite struct RiskCheckTests {
    @Test func parsesStructuredOutput() throws {
        let output = #"{"type":"result","is_error":false,"structured_output":{"verdict":"soft_deny","risk":"high","rule":"Git Destructive [named+specifics]: A force-push","summary":"Deletes release/2.1 on origin."}}"#
        let assessment = try RiskCheck.parse(cliOutput: Data(output.utf8))
        #expect(assessment.verdict == .softDeny)
        #expect(assessment.risk == .high)
        #expect(assessment.ruleName == "Git Destructive")
    }

    @Test func reportsCliErrors() {
        #expect(throws: RiskCheck.CheckError(description: "Not logged in")) {
            try RiskCheck.parse(cliOutput: Data(#"{"is_error":true,"result":"Not logged in"}"#.utf8))
        }
        #expect(throws: RiskCheck.CheckError.self) { try RiskCheck.parse(cliOutput: Data("boom".utf8)) }
    }

    @Test func extractsOnlyRealUserMessages() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"tidy up the repo"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"user","toolUseResult":{},"message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>noise</system-reminder>delete old branches too"}]}}"#,
            "not json",
        ]
        let transcript = Data(lines.joined(separator: "\n").utf8)
        #expect(RiskCheck.recentUserMessages(transcript: transcript, limit: 5) == ["tidy up the repo", "delete old branches too"])
        #expect(RiskCheck.recentUserMessages(transcript: transcript, limit: 1) == ["delete old branches too"])
    }

    @Test func inputCarriesContext() throws {
        let text = try RiskCheck.input(
            for: PermissionRequest(action: "Push", command: "git push -f", reason: "rebased"),
            session: SessionInfo(name: "x", cwd: "~/app"),
            recentUserMessages: ["rebase it"]
        )
        #expect(text.contains(#""recent_user_messages":["rebase it"]"#))
        #expect(text.contains(#""cwd":"~/app""#))
        #expect(!text.contains("auto_mode_blocked"))
        #expect(!text.contains("git_status"))
    }

    @Test func inputOfBlockedCallCarriesCategoryAndGitStatus() throws {
        let blocked = BlockedCall(
            toolName: "Bash", category: "Destructive or Unwanted Actions", reason: "[Destructive or Unwanted Actions]",
            hardDeny: false, projectRoot: "/app", suggestions: []
        )
        let text = try RiskCheck.input(
            for: PermissionRequest(action: "Rerun", command: "git checkout -- .", reason: "rerun", blocked: blocked),
            session: SessionInfo(name: "x", cwd: "/app"),
            recentUserMessages: [],
            gitStatus: "## main\n M a.swift"
        )
        #expect(text.contains(#""auto_mode_blocked":"Destructive or Unwanted Actions""#))
        #expect(text.contains(###""git_status":"## main\n M a.swift""###))
    }

    @Test func parsesRiskyPart() throws {
        let output = #"{"is_error":false,"structured_output":{"verdict":"soft_deny","risk":"high","rule":null,"summary":"Throws away changes.","severity":"medium","reversibility":"No undo.","risky_part":"git checkout -q -- ."}}"#
        #expect(try RiskCheck.parse(cliOutput: Data(output.utf8)).riskyPart == "git checkout -q -- .")
        // Results from before the field existed still parse.
        let old = #"{"is_error":false,"structured_output":{"verdict":"allow","risk":"low","rule":null,"summary":"Lists files."}}"#
        #expect(try RiskCheck.parse(cliOutput: Data(old.utf8)).riskyPart == nil)
    }

    @Test func keepsOnlyARiskyPartTheCommandContains() {
        let command = #"pnpm e2e; for db in $(psql -lqt); do dropdb "$db"; done; git checkout -q -- ."#
        #expect(RiskCheck.riskyPart("git checkout -q -- .", in: command) == "git checkout -q -- .")
        #expect(RiskCheck.riskyPart("  dropdb \"$db\" ", in: command) == #"dropdb "$db""#)
        #expect(RiskCheck.riskyPart("git reset --hard", in: command) == nil)
        #expect(RiskCheck.riskyPart("", in: command) == nil)
        #expect(RiskCheck.riskyPart("rm", in: nil) == nil)
    }

    @Test func pointsOnlyAtPartOfTheCommand() {
        #expect(RiskCheck.partToPoint("git checkout -- .", in: "pnpm test; git checkout -- .") == "git checkout -- .")
        #expect(RiskCheck.partToPoint("git push --force origin main", in: " git push --force origin main\n") == nil)
        #expect(RiskCheck.partToPoint(nil, in: "ls") == nil)
    }

    @Test func shortensGitStatus() {
        let files = (1...45).map { " M file\($0).swift" }
        let status = RiskCheck.gitStatus(porcelain: (["## main...origin/main"] + files).joined(separator: "\n") + "\n", maxFiles: 40)
        let lines = status?.split(separator: "\n").map(String.init) ?? []
        #expect(lines.first == "## main...origin/main")
        #expect(lines.count == 42)
        #expect(lines.last == "… and 5 more files")
        #expect(RiskCheck.gitStatus(porcelain: "## main\n") == "## main\n(no uncommitted changes)")
        #expect(RiskCheck.gitStatus(porcelain: "") == nil)
    }
}

@Suite struct BlockedCallExplanationTests {
    private let token = "ghp_abcdefghijklmnopqrstuvwxyz0123" // gitleaks:allow (test fixture)

    private func blocked(explanation: RiskAssessment?) -> BlockedCall {
        BlockedCall(
            toolName: "Bash", category: "Destructive or Unwanted Actions", reason: "[Destructive or Unwanted Actions]",
            hardDeny: false, projectRoot: "/app", suggestions: [], explanation: explanation
        )
    }

    @Test func decodesCallsFromBeforeExplanations() throws {
        let json = #"{"toolName":"Bash","reason":"[X]","hardDeny":false,"projectRoot":"/app","suggestions":[]}"#
        #expect(try JSONDecoder().decode(BlockedCall.self, from: Data(json.utf8)).explanation == nil)
    }

    @Test func historyMasksSecretsInTheExplanation() {
        let explanation = RiskAssessment(
            verdict: .softDeny, risk: .high, rule: nil, summary: "Sends GITHUB_TOKEN=\(token) to a new host.",
            severity: .critical, reversibility: "No undo.", riskyPart: "GITHUB_TOKEN=\(token) curl"
        )
        let kept = blocked(explanation: explanation).forHistory.explanation
        #expect(kept?.summary.contains(token) == false)
        #expect(kept?.riskyPart?.contains(token) == false)
        #expect(blocked(explanation: nil).forHistory.explanation == nil)
    }

    @Test func historyEntryTakesSeverityFromTheExplanation() {
        let explanation = RiskAssessment(
            verdict: .softDeny, risk: .high, rule: nil, summary: "Drops the _pend databases.",
            severity: .high, reversibility: "Gone unless a backup exists.", riskyPart: "dropdb"
        )
        let request = StewRequest(
            session: SessionInfo(name: "x", cwd: "/app"),
            prompt: .permission(PermissionRequest(action: "Rerun", command: "dropdb x", reason: "r", blocked: blocked(explanation: explanation)))
        )
        let entry = HistoryEntry.record(request, received: Date(), response: StewResponse(status: .denied), ended: Date())
        #expect(entry.severity == .high)
        #expect(entry.reversibility == "Gone unless a backup exists.")
        #expect(entry.blocked?.explanation?.summary == "Drops the _pend databases.")
        guard case .permission(let kept)? = entry.request?.prompt else { Issue.record("no request kept"); return }
        #expect(kept.blocked?.explanation?.riskyPart == "dropdb")
    }
}

@Suite struct CommandTextTests {
    @Test func masksKnownSecretShapes() {
        let cases: [(String, String)] = [
            ("GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123 gh pr list", "GITHUB_TOKEN=•••• gh pr list"),
            (#"curl -H "Authorization: Bearer abc.def-123" https://api.example.com"#, #"curl -H "Authorization: Bearer ••••" https://api.example.com"#), // gitleaks:allow (test fixture)
            ("psql postgres://app:hunter2@db.internal/app", "psql postgres://app:••••@db.internal/app"),
            ("mytool --password 's3cr3t value' --verbose", "mytool --password '••••' --verbose"),
            ("aws s3 ls --profile x AKIAABCDEFGHIJKLMNOP", "aws s3 ls --profile x ••••"), // gitleaks:allow (test fixture)
            ("curl -u admin:pa55word https://x", "curl -u admin:•••• https://x"),
        ]
        for (command, expected) in cases {
            #expect(CommandText.masked(command) == expected, "got: \(CommandText.masked(command))")
        }
    }

    @Test func leavesOrdinaryCommandsAlone() {
        for command in ["git push --force origin main", "git show 3f2a9c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39", "mkdir -p /tmp/a/b", "ls ~/Library/Application\\ Support"] {
            #expect(CommandText.masked(command) == command)
        }
    }

    @Test func masksLongRandomTokens() {
        #expect(CommandText.masked("deploy --key Xy7pQ2mN9vR4tL8wK3jH6fD1sA5gZ0cB") == "deploy --key ••••")
    }

    @Test func leavesPathsAndDotfilesAlone() {
        let commands = [
            #"docker run --rm -i hadolint/hadolint:latest < /Users/abby/.claude/worktrees/agent-a77993da5667c2e4d/Dockerfile; echo "exit=$?""#,
            "cat /Users/abby/.config/gcloud/configurations/config_Default2024",
            "ls ~/.ssh/known_hosts ~/.zshrc /Users/sam/.foo/bar",
            "swift test --filter StewCoreTests/CommandTextTests/leavesPathsAndDotfilesAlone2",
            "open ~/Library/Developer/Xcode/DerivedData/Stew-ab12cd34ef56gh78/Build/Products/Debug",
            "cp Sources/StewCore/CommandText.swift /tmp/Backup2026/StewCore/CommandText.swift",
            "ls ~/Library/Developer/CoreSimulator/Devices/1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D/data/Containers",
        ]
        for command in commands {
            #expect(CommandText.masked(command) == command, "got: \(CommandText.masked(command))")
        }
    }

    @Test func stillMasksSecretsNextToPaths() {
        let cases: [(String, String)] = [
            ("API_KEY=Xy7pQ2mN9vR4 ./deploy.sh ~/.config/app", "API_KEY=•••• ./deploy.sh ~/.config/app"),
            (#"DB_PASSWORD="correct horse" psql -f /Users/abby/.psqlrc"#, #"DB_PASSWORD="••••" psql -f /Users/abby/.psqlrc"#),
            ("cat ~/.netrc && echo ghp_abcdefghijklmnopqrstuvwxyz0123", "cat ~/.netrc && echo ••••"), // gitleaks:allow (test fixture)
            ("glpat-abcdefghij0123456789xy push", "•••• push"), // gitleaks:allow (test fixture)
            ("echo sk-ant-api03-abcdefghijklmnopqrstuvwx > ~/.anthropic", "echo •••• > ~/.anthropic"), // gitleaks:allow (test fixture)
            ("git clone https://abby:Tr0ub4dor@git.example.com/team/repo.git", "git clone https://abby:••••@git.example.com/team/repo.git"), // gitleaks:allow (test fixture)
            ("curl https://hooks.example.com/services/T01ABCDEF/B02GHIJKL/Xy7pQ2mN9vR4tL8wK3jH6fD1", "curl https://hooks.example.••••"), // gitleaks:allow (test fixture)
            ("aws configure set secret Xy7pQ2mN9vR4/tL8wK3jH6fD1sA5gZ0cBq9", "aws configure set secret ••••"), // gitleaks:allow (test fixture)
        ]
        for (command, expected) in cases {
            #expect(CommandText.masked(command) == expected, "got: \(CommandText.masked(command))")
        }
    }

    @Test func wildcardsSecretsForRules() {
        #expect(CommandText.wildcarded("API_KEY=sk-abcdefghijklmnopqrstuv npm run deploy") == "API_KEY=* npm run deploy")
    }

    @Test func detectsCompoundCommands() {
        for command in ["a && b", "a; b", "a | b", "echo x > f", "echo $(whoami)", "echo `id`", "sleep 1 &", "(cd x)", "echo \"$(id)\""] {
            #expect(CommandText.isCompound(command), "\(command)")
        }
        for command in ["git push origin main", "echo 'a && b'", "echo \"a; b\"", "grep -e 'x|y' f", #"echo \;"#] {
            #expect(!CommandText.isCompound(command), "\(command)")
        }
    }

    @Test func suggestsExactThenPrefixesKeepingSubcommand() {
        let suggestions = CommandText.ruleSuggestions(for: "git push --force origin main")
        #expect(suggestions.map(\.pattern) == ["git push --force origin main", "git push --force origin *", "git push --force *"])
        #expect(suggestions.first?.kind == .exact)
        #expect(CommandText.ruleSuggestions(for: "ls build").map(\.pattern) == ["ls build", "ls *"])
    }

    @Test func noPrefixesForInterpretersOrCompounds() {
        #expect(CommandText.ruleSuggestions(for: "python3 -c 'import os'").map(\.pattern) == ["python3 -c 'import os'"])
        #expect(CommandText.ruleSuggestions(for: "npm test && rm -rf dist").isEmpty)
    }

    @Test func suggestionsNeverContainSecrets() {
        let suggestions = CommandText.ruleSuggestions(for: #"curl -H "Authorization: Bearer abcdef123456" https://api.example.com/items"#) // gitleaks:allow (test fixture)
        #expect(suggestions.allSatisfy { !$0.pattern.contains("abcdef123456") })
        #expect(suggestions.first?.pattern == #"curl -H "Authorization: Bearer *" https://api.example.com/items"#)
    }

    @Test func wildcardMatching() {
        #expect(CommandText.matches(pattern: "npm run *", command: "npm run build"))
        #expect(CommandText.matches(pattern: "npm run *", command: "npm run"))
        #expect(!CommandText.matches(pattern: "npm run *", command: "npm install"))
        #expect(CommandText.matches(pattern: "git log * main", command: "git log --oneline main"))
        #expect(!CommandText.matches(pattern: "git log * main", command: "git log main"))
        #expect(CommandText.matches(pattern: "git push", command: "git push"))
        #expect(!CommandText.matches(pattern: "git push", command: "git push -f"))
    }
}

@Suite struct GrantBookTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func call(_ command: String, session: String = "s1") -> HookCall {
        HookCall(event: "PreToolUse", sessionID: session, cwd: "/p", toolName: "Bash", key: "{\"command\":\"\(command)\"}", command: command, description: nil, summary: command, reason: nil)
    }

    @Test func onceAllowsOneIdenticalRetryInTheSameSession() {
        var grants = [GrantBook.once(for: call("git push -f"), now: now)]
        #expect(GrantBook.preToolUse(grants: &grants, call: call("git push -f", session: "other"), projectRoot: { "/p" }, now: now) == nil)
        #expect(GrantBook.preToolUse(grants: &grants, call: call("git push -f --tags"), projectRoot: { "/p" }, now: now) == nil)
        #expect(GrantBook.preToolUse(grants: &grants, call: call("git push -f"), projectRoot: { "/p" }, now: now) == .allow)
        #expect(GrantBook.preToolUse(grants: &grants, call: call("git push -f"), projectRoot: { "/p" }, now: now) == nil)
    }

    @Test func denyNoteReachesClaudeOnce() {
        var grants = [GrantBook.denyNote(for: call("rm -rf dist"), note: "use make clean", now: now)]
        #expect(GrantBook.preToolUse(grants: &grants, call: call("rm -rf dist"), projectRoot: { "/p" }, now: now) == .deny(note: "use make clean"))
        #expect(grants.isEmpty)
    }

    @Test func expiredGrantsAreDropped() {
        var grants = [GrantBook.once(for: call("x"), now: now)]
        let later = now.addingTimeInterval(GrantBook.onceLifetime + 1)
        #expect(GrantBook.preToolUse(grants: &grants, call: call("x"), projectRoot: { "/p" }, now: later) == nil)
        #expect(grants.isEmpty)
    }

    @Test func patternGrantMatchesSimpleCommandsInItsProjectOnly() {
        let choice = GrantChoice(scope: .init(kind: .pattern, value: "git push --force *"), duration: .hour)
        var grants = [GrantBook.standing(choice, toolName: "Bash", projectRoot: "/p", now: now)!]
        #expect(GrantBook.preToolUse(grants: &grants, call: call("git push --force origin dev"), projectRoot: { "/p" }, now: now) == .allow)
        #expect(GrantBook.preToolUse(grants: &grants, call: call("git push --force origin dev"), projectRoot: { "/other" }, now: now) == nil)
        #expect(GrantBook.preToolUse(grants: &grants, call: call("git push --force origin dev && rm -rf ~"), projectRoot: { "/p" }, now: now) == nil)
        #expect(GrantBook.preToolUse(grants: &grants, call: call("git push --force x"), projectRoot: { "/p" }, now: now.addingTimeInterval(3601)) == nil)
    }

    @Test func categoryGrantIsPerProject() {
        let choice = GrantChoice(scope: .init(kind: .category, value: "Destructive or Unwanted Actions"), duration: .always)
        let grants = [GrantBook.standing(choice, toolName: "Bash", projectRoot: "/p", now: now)!]
        #expect(GrantBook.categoryGrant(grants: grants, toolName: "Bash", category: "Destructive or Unwanted Actions", projectRoot: "/p", now: now) != nil)
        #expect(GrantBook.categoryGrant(grants: grants, toolName: "Bash", category: "Destructive or Unwanted Actions", projectRoot: "/q", now: now) == nil)
        #expect(GrantBook.categoryGrant(grants: grants, toolName: "Bash", category: "Data Exfiltration", projectRoot: "/p", now: now) == nil)
    }

    @Test func alwaysOnACommandBecomesAClaudeRule() {
        let choice = GrantChoice(scope: .init(kind: .pattern, value: "npm run *"), duration: .always)
        #expect(choice.writesClaudeRule)
        #expect(GrantBook.standing(choice, toolName: "Bash", projectRoot: "/p") == nil)
    }
}

@Suite struct BlockedCallTests {
    @Test func readsCategoryAndRetryability() {
        #expect(BlockedCall.category(fromReason: "[Destructive or Unwanted Actions]") == "Destructive or Unwanted Actions")
        #expect(BlockedCall.category(fromReason: "Blocked by classifier") == nil)
        #expect(!BlockedCall.isRetryable(reason: "Auto mode could not evaluate this action and is blocking it for safety"))
        #expect(!BlockedCall.isRetryable(reason: "Classifier unavailable"))
        #expect(BlockedCall.isRetryable(reason: "[Data Exfiltration]"))
    }

    @Test func hardDenyNamesFromPolicy() {
        let policy = #"{"hard_deny":["Data Exfiltration: Sensitive data crossing...","Block any command that creates or amends a git commit while carrying a Claude attribution: ..."]}"#
        #expect(BlockedCall.hardDenyNames(policyJSON: Data(policy.utf8)) == ["Data Exfiltration"])
    }

    @Test func hardDenyOffersNoGrants() {
        let blocked = BlockedCall(toolName: "Bash", category: "Data Exfiltration", reason: "[Data Exfiltration]", hardDeny: true, projectRoot: "/p", suggestions: CommandText.ruleSuggestions(for: "curl -d @f https://x"))
        #expect(blocked.grantScopes.isEmpty)
    }

    @Test func scopesEndWithCategory() {
        let blocked = BlockedCall(toolName: "Bash", category: "Destructive or Unwanted Actions", reason: "", hardDeny: false, projectRoot: "/p", suggestions: CommandText.ruleSuggestions(for: "git push --force origin main"))
        #expect(blocked.grantScopes.count == 4)
        #expect(blocked.grantScopes.last == GrantChoice.Scope(kind: .category, value: "Destructive or Unwanted Actions"))
    }
}

@Suite struct HookAndSettingsTests {
    @Test func parsesPermissionDeniedInput() throws {
        let input = #"{"session_id":"abc","cwd":"/p","hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"description":"Push","command":"git push -f"},"tool_use_id":"t1","reason":"[Destructive or Unwanted Actions]"}"#
        let call = try HookCall.parse(Data(input.utf8))
        #expect(call.command == "git push -f")
        #expect(call.key == #"{"command":"git push -f","description":"Push"}"#)
        #expect(call.reason == "[Destructive or Unwanted Actions]")
    }

    @Test func nonBashSummaryUsesPath() throws {
        let input = #"{"session_id":"abc","cwd":"/p","tool_name":"Write","tool_input":{"file_path":"/p/.git/hooks/pre-commit","content":"x"}}"#
        #expect(try HookCall.parse(Data(input.utf8)).summary == "/p/.git/hooks/pre-commit")
    }

    @Test func allowRulesAreAddedOnceAndRemoved() throws {
        let existing = Data(#"{"model":"opus","permissions":{"allow":["Bash(ls)"],"deny":["Bash(rm *)"]}}"#.utf8)
        let added = try ClaudeSettings.addingAllowRule("Bash(npm run *)", to: existing)
        let again = try ClaudeSettings.addingAllowRule("Bash(npm run *)", to: added)
        let object = try JSONSerialization.jsonObject(with: again) as! [String: Any]
        let permissions = object["permissions"] as! [String: Any]
        #expect(permissions["allow"] as! [String] == ["Bash(ls)", "Bash(npm run *)"])
        #expect(permissions["deny"] as! [String] == ["Bash(rm *)"])
        #expect(object["model"] as? String == "opus")
        let removed = try ClaudeSettings.removingAllowRule("Bash(npm run *)", from: again)
        let after = (try JSONSerialization.jsonObject(with: removed) as! [String: Any])["permissions"] as! [String: Any]
        #expect(after["allow"] as! [String] == ["Bash(ls)"])
    }

    @Test func hooksInstallIdempotentlyAndUninstallCleanly() throws {
        let existing = Data(#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-tool check"}]}]}}"#.utf8)
        let once = try ClaudeSettings.installingHooks(executable: "/u/.local/bin/stew", deniedTimeout: 1800, into: existing)
        let twice = try ClaudeSettings.installingHooks(executable: "/u/.local/bin/stew", deniedTimeout: 1800, into: once)
        let hooks = (try JSONSerialization.jsonObject(with: twice) as! [String: Any])["hooks"] as! [String: Any]
        #expect((hooks["PreToolUse"] as! [[String: Any]]).count == 3)
        #expect((hooks["PermissionDenied"] as! [[String: Any]]).count == 1)
        #expect(ClaudeSettings.hasHooks(executable: "/u/.local/bin/stew", in: twice))
        let removed = try #require(try ClaudeSettings.removingHooks(executable: "/u/.local/bin/stew", from: twice))
        let left = (try JSONSerialization.jsonObject(with: removed) as! [String: Any])["hooks"] as! [String: Any]
        #expect((left["PreToolUse"] as! [[String: Any]]).count == 1)
        #expect(left["PermissionDenied"] == nil)
    }

    @Test func uninstallWithoutHooksLeavesTheFileAlone() throws {
        let untouched = Data(#"{"zeta": 1,   "alpha": {"b": true}}"#.utf8)
        #expect(try ClaudeSettings.removingHooks(executable: "/u/.local/bin/stew", from: untouched) == nil)
        #expect(try ClaudeSettings.removingHooks(executable: "/u/.local/bin/stew", from: nil) == nil)
    }
}

@Suite struct TranscriptTests {
    @Test func lastAssistantTextSkipsToolOnlyMessages() {
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"First I will look."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"The remote has the old history, so I need to force-push."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","message":{"content":"ok"}}"#,
        ]
        #expect(RiskCheck.lastAssistantText(transcript: Data(lines.joined(separator: "\n").utf8)) == "The remote has the old history, so I need to force-push.")
        #expect(RiskCheck.lastAssistantText(transcript: Data()) == nil)
    }
}

@Suite struct TimeLimitTests {
    let session = SessionInfo(name: "s")

    @Test func defaultAppliesToPermissionsAndQuestionsOnly() {
        let permission = StewRequest(session: session, prompt: .permission(PermissionRequest(action: "a", reason: "r")))
        let notify = StewRequest(session: session, prompt: .notify(NotifyRequest(title: "t")))
        #expect(permission.timeLimit(defaultTimeout: 300) == 300)
        #expect(notify.timeLimit(defaultTimeout: 300) == nil)
        #expect(permission.timeLimit(defaultTimeout: 0) == nil)
    }

    @Test func explicitTimeoutWinsAndZeroMeansNone() {
        var request = StewRequest(session: session, prompt: .permission(PermissionRequest(action: "a", reason: "r")), timeout: 30)
        #expect(request.timeLimit(defaultTimeout: 300) == 30)
        request.timeout = 0
        #expect(request.timeLimit(defaultTimeout: 300) == nil)
    }

    @Test func noteTellsClaudeToMoveOn() {
        let request = StewRequest(session: session, prompt: .permission(PermissionRequest(action: "a", reason: "r")))
        #expect(request.timeoutNote(after: 300).hasPrefix("The user didn't respond within 5 min."))
        #expect(request.timeoutNote(after: 20).contains("within 20 s"))
    }

    @Test func maxWaitRoundTrips() throws {
        let request = StewRequest(session: session, prompt: .permission(PermissionRequest(action: "a", reason: "r")), maxWait: 1780)
        #expect(try Wire.decode(StewRequest.self, line: try Wire.encode(request).dropLast()).maxWait == 1780)
    }

    @Test func extendKeyDoesNotClash() throws {
        let keymap = try Keymap(config: StewConfig())
        #expect(keymap[.extend].description == "⌘E")
        let clash = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"keys":{"extend":"d"}}"#.utf8))
        #expect(throws: Shortcut.ParseError.self) { try Keymap(config: clash) }
    }
}

@Suite struct ShortcutSpecTests {
    @Test func specRoundTrips() throws {
        let keymap = try Keymap(config: StewConfig())
        for shortcut in Array(keymap.actions.values) + keymap.options + [Shortcut(modifiers: [.control, .option], key: .special(.left))] {
            #expect(try Shortcut.parse(shortcut.spec, chord: []) == shortcut, "\(shortcut.spec)")
        }
        #expect(keymap[.dismissAll].spec == "shift+cmd+.")
    }

    @Test func defaultsGiveOneMinute() {
        #expect(StewConfig().responseTimeout == 60)
        #expect(StewConfig().extendBy == 120)
    }
}

@Suite struct QuestionRoutingTests {
    @Test func unattendedRoutesOnlyBackgroundSessions() {
        #expect(QuestionRouting.shouldRoute(mode: "unattended", attended: "0"))
        #expect(!QuestionRouting.shouldRoute(mode: "unattended", attended: "1"))
        #expect(!QuestionRouting.shouldRoute(mode: "unattended", attended: nil))
        #expect(QuestionRouting.shouldRoute(mode: "always", attended: "1"))
        #expect(!QuestionRouting.shouldRoute(mode: "never", attended: "0"))
        #expect(StewDefaults.route == "unattended")
    }

    @Test func answerEchoesInputAndAddsAnswers() throws {
        let input = #"{"questions":[{"header":"Color","multiSelect":false,"options":[{"description":"","label":"Red"},{"description":"","label":"Blue"}],"question":"Which color?"}]}"#
        let output = try #require(HookOutput.answeringQuestions(inputJSON: input, answers: ["Which color?": "Blue"]))
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        let specific = object["hookSpecificOutput"] as! [String: Any]
        #expect(specific["permissionDecision"] as? String == "allow")
        let updated = specific["updatedInput"] as! [String: Any]
        #expect(updated["answers"] as? [String: String] == ["Which color?": "Blue"])
        #expect((updated["questions"] as? [[String: Any]])?.count == 1)
    }

    @Test func installAddsQuestionHookWithLongTimeout() throws {
        let installed = try ClaudeSettings.installingHooks(executable: "/u/stew", deniedTimeout: 1800, into: nil)
        let hooks = (try JSONSerialization.jsonObject(with: installed) as! [String: Any])["hooks"] as! [String: Any]
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        let question = try #require(pre.first { $0["matcher"] as? String == "AskUserQuestion" })
        #expect(((question["hooks"] as! [[String: Any]])[0]["timeout"] as? Int) == 1800)
        #expect(ClaudeSettings.hookState(executable: "/u/stew", in: installed) == .complete)
        let old = Data(#"{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/u/stew hook pre"}]}]}}"#.utf8)
        #expect(ClaudeSettings.hookState(executable: "/u/stew", in: old) == .partial)
    }
}

private enum StewDefaults {
    static let route = StewConfig().routeQuestions
}

@Suite struct ConfettiTests {
    static let permission = Prompt.permission(PermissionRequest(action: "Deploy", reason: "release"))

    @Test func offByDefaultAndReadFromConfig() throws {
        #expect(StewConfig().confetti == false)
        let config = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"confetti":true}"#.utf8))
        #expect(config.confetti)
    }

    @Test func onlyAnApprovedPermissionCelebrates() {
        var config = StewConfig()
        config.confetti = true
        let grant = GrantChoice(scope: GrantChoice.Scope(kind: .category, value: "Destructive"), duration: .hour)
        #expect(config.celebrates(StewResponse(status: .approved), to: Self.permission))
        #expect(config.celebrates(StewResponse(status: .approved, grant: grant), to: Self.permission))
        #expect(!config.celebrates(StewResponse(status: .denied), to: Self.permission))
        #expect(!config.celebrates(StewResponse(status: .timeout), to: Self.permission))
        #expect(!config.celebrates(StewResponse(status: .acknowledged), to: .notify(NotifyRequest(title: "Done"))))
        #expect(!config.celebrates(StewResponse(status: .answered), to: .question(QuestionSet(questions: []))))
        config.confetti = false
        #expect(!config.celebrates(StewResponse(status: .approved), to: Self.permission))
    }
}

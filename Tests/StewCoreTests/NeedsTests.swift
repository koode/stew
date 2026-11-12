import Foundation
import Testing
@testable import StewCore

private let session = SessionInfo(name: "release job", id: "aaaa-1111", cwd: "~/code/app")
private let otherSession = SessionInfo(name: "mobile", id: "bbbb-2222", cwd: "~/code/mobile")
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func item(_ id: String, title: String = "Log in", in itemSession: SessionInfo = session, automatic: Bool = false) -> NeedsItem {
    NeedsItem(id: id, created: start, session: itemSession, needs: NeedsRequest(title: title, automatic: automatic))
}

@Suite struct NeedsRequestTests {
    @Test func acceptsAFullRequest() throws {
        let needs = NeedsRequest(
            title: "Log in to npm",
            why: "Publishing failed with E401.",
            steps: ["Run the command", "Finish in the browser"],
            commands: [NeedsCommand(command: "npm login")],
            links: [NeedsLink(url: "https://www.npmjs.com/login"), NeedsLink(label: "Docs", url: "http://example.com/x")]
        )
        try needs.validate()
    }

    @Test func refusesBadInput() {
        let refused: [(NeedsRequest, String)] = [
            (NeedsRequest(title: "  "), "the title is empty"),
            (NeedsRequest(title: "two\nlines"), "the title must be one line"),
            (NeedsRequest(title: String(repeating: "x", count: 201)), "longer than 200"),
            (NeedsRequest(title: "x", steps: ["ok", " "]), "a step is empty"),
            (NeedsRequest(title: "x", commands: [NeedsCommand(command: "")]), "a command is empty"),
            (NeedsRequest(title: "x", links: [NeedsLink(url: "file:///Applications/Calculator.app")]), "not an http or https URL"),
            (NeedsRequest(title: "x", links: [NeedsLink(url: "javascript:alert(1)")]), "not an http or https URL"),
            (NeedsRequest(title: "x", links: [NeedsLink(url: "https://")]), "not an http or https URL"),
            (NeedsRequest(title: "x", steps: Array(repeating: "s", count: 21)), "at most 20 steps"),
        ]
        for (needs, message) in refused {
            do {
                try needs.validate()
                Issue.record("accepted \(needs)")
            } catch {
                #expect("\(error)".contains(message), "\(error) should mention \(message)")
            }
        }
    }

    @Test func linkTextDropsTheScheme() {
        #expect(NeedsLink(url: "https://example.com/a").displayText == "example.com/a")
        #expect(NeedsLink(label: "Console", url: "https://example.com/a").displayText == "Console")
    }

    @Test func travelsOverTheWireAndHasNoTimeLimit() throws {
        let request = StewRequest(session: session, prompt: .needs(NeedsRequest(title: "Plug in the YubiKey", steps: ["Plug it in"])), timeout: 30, wait: true)
        let line = try Wire.encode(request)
        #expect(String(decoding: line, as: UTF8.self).contains(#""kind":"needs""#))
        #expect(try Wire.decode(StewRequest.self, line: line.dropLast()) == request)
        // --timeout limits only how long the caller waits; the panel shows no clock.
        #expect(request.timeLimit(defaultTimeout: 60) == nil)
    }

    @Test func decodesWithOnlyATitle() throws {
        let decoded = try JSONDecoder().decode(NeedsRequest.self, from: Data(#"{"title":"Buy more credits"}"#.utf8))
        #expect(decoded == NeedsRequest(title: "Buy more credits"))
    }

    @Test func doneAndResolvedExitZeroAndCarryTheID() throws {
        #expect(StewResponse(status: .done).exitCode == 0)
        #expect(StewResponse(status: .resolved).exitCode == 0)
        let line = String(decoding: try Wire.encode(StewResponse(status: .shown, id: "3f9a1c2e")), as: UTF8.self)
        #expect(line == #"{"id":"3f9a1c2e","status":"shown"}"# + "\n")
    }
}

@Suite struct NeedsBookTests {
    @Test func automaticItemReplacesTheSessionsEarlierOne() {
        var items = [item("a1", automatic: true), item("m1"), item("o1", in: otherSession, automatic: true)]
        let replaced = NeedsBook.add(item("a2", title: "Newer", automatic: true), to: &items)
        #expect(replaced.map(\.id) == ["a1"])
        #expect(items.map(\.id) == ["m1", "o1", "a2"])
    }

    @Test func itemsFromTheCLIAreNeverReplaced() {
        var items = [item("m1")]
        #expect(NeedsBook.add(item("m2"), to: &items).isEmpty)
        #expect(items.map(\.id) == ["m1", "m2"])
    }

    @Test func automaticItemWithoutASessionIDReplacesNothing() {
        let noID = SessionInfo(name: "x")
        var items = [item("a1", in: noID, automatic: true)]
        #expect(NeedsBook.add(item("a2", in: noID, automatic: true), to: &items).isEmpty)
        #expect(items.count == 2)
    }

    @Test func aMessageAnswersOnlyThatSessionsAutomaticItems() {
        let items = [item("a1", automatic: true), item("m1"), item("o1", in: otherSession, automatic: true)]
        #expect(NeedsBook.answeredBy(sessionID: "aaaa-1111", in: items).map(\.id) == ["a1"])
        #expect(NeedsBook.answeredBy(sessionID: "", in: items).isEmpty)
        #expect(NeedsBook.answeredBy(sessionID: "zzzz", in: items).isEmpty)
    }

    @Test func newIDsAreShortAndUnique() {
        var draws = [UUID(uuidString: "3F9A1C2E-0000-0000-0000-000000000000")!, UUID(uuidString: "7B00D1E5-0000-0000-0000-000000000000")!]
        let id = NeedsBook.newID(existing: [item("3f9a1c2e")]) { draws.removeFirst() }
        #expect(id == "7b00d1e5")
        #expect(NeedsBook.newID(existing: []).count == 8)
    }

    @Test func persistsAndToleratesABrokenFile() throws {
        var parked = item("a1", automatic: true)
        parked.parked = true
        parked.needs.commands = [NeedsCommand(label: "Login", command: "npm login --token ghp_abcdefghijklmnopqrstuvwxyz0123456789")] // gitleaks:allow (test fixture)
        let data = try NeedsBook.encode([parked, item("m1")])
        #expect(NeedsBook.decode(data) == [parked, item("m1")])
        // The file keeps the command as given, so the copy button copies the real one.
        #expect(String(decoding: data, as: UTF8.self).contains("ghp_"))
        #expect(NeedsBook.decode(Data("not json".utf8)).isEmpty)
        #expect(NeedsBook.decode(Data()).isEmpty)
    }

    @Test func countText() {
        #expect(NeedsBook.countText(1) == "1 thing needs you")
        #expect(NeedsBook.countText(2) == "2 things need you")
    }

    @Test func anOpenCLIItemBlocksAnAutomaticOne() {
        let items = [item("m1"), item("a1", in: otherSession, automatic: true)]
        #expect(NeedsBook.hasOpenCLIItem(sessionID: "aaaa-1111", in: items))
        #expect(!NeedsBook.hasOpenCLIItem(sessionID: "bbbb-2222", in: items))
        #expect(!NeedsBook.hasOpenCLIItem(sessionID: nil, in: items))
        #expect(!NeedsBook.hasOpenCLIItem(sessionID: "", in: items))
    }
}

@Suite struct PanelQueueTests {
    /// "P" is a permission, question or notification; "N" a needs item.
    private func order(_ kinds: String, pinned: Bool = false) -> String {
        let tagged = kinds.enumerated().map { "\($0.element)\($0.offset)" }
        return PanelQueue.ordered(tagged, frontPinned: pinned) { $0.hasPrefix("N") }.joined(separator: " ")
    }

    @Test func needsWaitBehindEverythingElse() {
        #expect(order("NP") == "P1 N0")
        #expect(order("NNPP") == "P2 P3 N0 N1")
        #expect(order("PNP") == "P0 P2 N1")
        #expect(order("") == "")
    }

    @Test func aNeedsItemTheUserTypesOnKeepsTheFront() {
        #expect(order("NP", pinned: true) == "N0 P1")
        #expect(order("NNP", pinned: true) == "N0 P2 N1")
        #expect(order("PNP", pinned: true) == "P0 P2 N1")
    }
}

@Suite struct ReturnSummaryTests {
    @Test func countsMissedRequestsAndOpenNeeds() throws {
        #expect(ReturnSummary.notice(missedCount: 0, needsCount: 0) == nil)
        let missedOnly = try #require(ReturnSummary.notice(missedCount: 3, needsCount: 0))
        #expect(missedOnly == NotifyRequest(title: "3 requests timed out while you were away", level: .warning, action: .openHistory))
        let both = try #require(ReturnSummary.notice(missedCount: 1, needsCount: 2))
        #expect(both.title == "1 request timed out while you were away")
        #expect(both.body == "2 things need you.")
        #expect(both.action == .openHistory)
        let needsOnly = try #require(ReturnSummary.notice(missedCount: 0, needsCount: 1))
        #expect(needsOnly == NotifyRequest(title: "1 thing needs you", level: .info))
    }
}

@Suite struct NeedsParserTests {
    @Test func readsTitleNumberedStepsAndCodeBlocks() throws {
        let message = """
        The publish failed: npm says this machine is not logged in.

        Needs input: log in to npm so I can publish 2.4.0

        1. Run this in a terminal:
           ```bash
           npm login --auth-type=web
           ```
        2. Finish the login in the browser,
           then come back here.
        3. Tell me when it is done.

        After that I retry the publish.

        ```
        npm whoami
        ```
        """
        let needs = try #require(NeedsParser.parse(message))
        #expect(needs.title == "log in to npm so I can publish 2.4.0")
        #expect(needs.steps == ["Run this in a terminal:", "Finish the login in the browser, then come back here.", "Tell me when it is done."])
        #expect(needs.commands.map(\.command) == ["npm login --auth-type=web", "npm whoami"])
        #expect(needs.automatic)
        try needs.validate()
    }

    @Test func markerIsCaseInsensitiveAndMayBeBold() {
        #expect(NeedsParser.parse("NEEDS INPUT: approve the PR")?.title == "approve the PR")
        #expect(NeedsParser.parse("**Needs input:** approve the PR")?.title == "approve the PR")
        #expect(NeedsParser.parse("**Needs input**: approve the PR")?.title == "approve the PR")
        #expect(NeedsParser.parse("> needs input: plug in the phone")?.title == "plug in the phone")
    }

    @Test func needsTheMarkerAtTheStartOfALine() {
        #expect(NeedsParser.parse("All done, nothing needs input: carry on") == nil)
        #expect(NeedsParser.parse("Tests pass.") == nil)
        #expect(NeedsParser.parse("") == nil)
    }

    @Test func ignoresAMarkerInsideACodeBlock() {
        #expect(NeedsParser.parse("```\nneeds input: not this\n```") == nil)
    }

    @Test func emptyMarkerTakesTheNextLine() {
        #expect(NeedsParser.parse("needs input:\n\nApprove the deploy in the console\n")?.title == "Approve the deploy in the console")
        #expect(NeedsParser.parse("needs input:")?.title == "Claude needs your input")
    }

    @Test func stepsStopAtTheFirstPlainLine() {
        let needs = NeedsParser.parse("needs input: x\n1) one\n2) two\nThat is all.\n3. not a step")
        #expect(needs?.steps == ["one", "two"])
    }

    @Test func noListMeansNoSteps() {
        let needs = NeedsParser.parse("needs input: buy 10 more GPU credits\nThe job stopped at 80 percent.")
        #expect(needs?.steps == [])
        #expect(needs?.commands == [])
    }

    @Test func longTitlesAreShortened() throws {
        let needs = try #require(NeedsParser.parse("needs input: " + String(repeating: "a", count: 300)))
        #expect(needs.title.count == NeedsRequest.maxTitle)
        try needs.validate()
    }

    @Test func linksComeFromWebAddressesOutsideCodeBlocks() throws {
        let message = """
        needs input: approve the build at https://appstoreconnect.apple.com/apps/42.
        See [the runbook](https://wiki.example.com/release) and https://appstoreconnect.apple.com/apps/42 again,
        or (http://status.example.com/) for outages; not ftp://files.example.com.
        ```
        curl https://api.example.com/token
        ```
        Also https://one.example.com, https://two.example.com and https://three.example.com!
        """
        let needs = try #require(NeedsParser.parse(message))
        #expect(needs.links.map(\.url) == [
            "https://appstoreconnect.apple.com/apps/42",
            "https://wiki.example.com/release",
            "http://status.example.com/",
            "https://one.example.com",
        ])
        #expect(needs.links.allSatisfy { $0.label == nil })
        try needs.validate()
    }

    @Test func noAddressesMeansNoLinks() {
        #expect(NeedsParser.parse("needs input: plug in the phone")?.links == [])
    }
}

@Suite struct NeedsRoutingTests {
    @Test func autoNeedsFollowsTheModes() {
        #expect(AutoNeeds.shouldCreate(mode: "unattended", attended: "0"))
        #expect(!AutoNeeds.shouldCreate(mode: "unattended", attended: "1"))
        #expect(!AutoNeeds.shouldCreate(mode: "unattended", attended: nil))
        #expect(AutoNeeds.shouldCreate(mode: "always", attended: "1"))
        #expect(!AutoNeeds.shouldCreate(mode: "never", attended: "0"))
    }

    @Test func configDefaultsToUnattended() throws {
        #expect(StewConfig().autoNeeds == "unattended")
        let decoded = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"autoNeeds":"never"}"#.utf8))
        #expect(decoded.autoNeeds == "never")
    }

    @Test func readsTheTurnHookFields() {
        let stop = Data(#"{"session_id":"s1","cwd":"/w","transcript_path":"/t.jsonl","hook_event_name":"Stop","last_assistant_message":"needs input: x"}"#.utf8)
        #expect(TurnHookInput.parse(stop) == TurnHookInput(sessionID: "s1", cwd: "/w", transcriptPath: "/t.jsonl", lastAssistantMessage: "needs input: x"))
        let prompt = Data(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"done","last_assistant_message":""}"#.utf8)
        #expect(TurnHookInput.parse(prompt)?.lastAssistantMessage == nil)
        #expect(TurnHookInput.parse(Data("[]".utf8)) == nil)
    }
}

@Suite struct NeedsHistoryTests {
    @Test func recordsFinalOutcomesWithMaskedCommands() {
        var record = item("a1", title: "Log in to the registry")
        record.needs.why = "Pushing the image failed."
        record.needs.steps = ["Run the command", "Come back"]
        record.needs.commands = [NeedsCommand(command: "docker login -p ghp_abcdefghijklmnopqrstuvwxyz0123456789 ghcr.io")] // gitleaks:allow (test fixture)
        record.needs.links = [NeedsLink(url: "https://ghcr.io")]
        let entry = HistoryEntry.record(record, outcome: .done, note: "logged in", ended: start.addingTimeInterval(90))
        #expect(entry.kind == "needs")
        #expect(entry.summary == "Log in to the registry")
        #expect(entry.command == "docker login -p •••• ghcr.io")
        #expect(entry.detail == "Pushing the image failed.\n\n1. Run the command\n2. Come back\n\nhttps://ghcr.io")
        #expect(entry.outcome.label == "Done")
        #expect(entry.note == "logged in")
        #expect(!entry.missed)
        #expect(HistoryEntry.Outcome.resolvedByClaude.label == "Resolved by Claude")
        #expect(HistoryEntry.Outcome.answeredInSession.label == "Answered in session")
        #expect(HistoryEntry.outcome(of: StewResponse(status: .done)) == .done)
        #expect(HistoryEntry.outcome(of: StewResponse(status: .resolved)) == .resolvedByClaude)
    }

    @Test func movedOnHasItsOwnLabel() {
        #expect(HistoryEntry.Outcome.movedOn.label == "Moved on")
        #expect(!HistoryEntry.record(item("a1"), outcome: .movedOn, note: nil, ended: start).missed)
    }
}

@Suite struct NeedsHookInstallTests {
    private func hooks(_ data: Data) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["hooks"] as! [String: Any]
    }

    @Test func installsStopAndPromptHooksIdempotently() throws {
        let once = try ClaudeSettings.installingHooks(executable: "/u/stew", deniedTimeout: 1800, into: nil)
        let twice = try ClaudeSettings.installingHooks(executable: "/u/stew", deniedTimeout: 1800, into: once)
        #expect(once == twice)
        let installed = hooks(twice)
        let stop = try #require((installed["Stop"] as? [[String: Any]])?.first)
        #expect(stop["matcher"] == nil)
        let stopHandler = (stop["hooks"] as! [[String: Any]])[0]
        #expect(stopHandler["command"] as? String == "/u/stew hook stop")
        #expect(stopHandler["async"] as? Bool == true)
        let prompt = try #require((installed["UserPromptSubmit"] as? [[String: Any]])?.first)
        let promptHandler = (prompt["hooks"] as! [[String: Any]])[0]
        #expect(promptHandler["command"] as? String == "/u/stew hook prompt")
        #expect(promptHandler["async"] == nil)
        #expect(ClaudeSettings.hookState(executable: "/u/stew", in: twice) == .complete)
    }

    @Test func anInstallWithoutTheNeedsHooksIsPartial() {
        let previous = Data(#"""
        {"hooks":{"PermissionDenied":[{"matcher":"*","hooks":[{"type":"command","command":"/u/stew hook denied"}]}],
        "PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/u/stew hook pre"}]},
        {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"/u/stew hook question"}]}]}}
        """#.utf8)
        #expect(ClaudeSettings.hookState(executable: "/u/stew", in: previous) == .partial)
    }

    @Test func uninstallRemovesTheNeedsHooksAndKeepsOthers() throws {
        let existing = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8)
        let installed = try ClaudeSettings.installingHooks(executable: "/u/stew", deniedTimeout: 1800, into: existing)
        #expect((hooks(installed)["Stop"] as! [[String: Any]]).count == 2)
        let removed = try #require(try ClaudeSettings.removingHooks(executable: "/u/stew", from: installed))
        let left = hooks(removed)
        #expect((left["Stop"] as! [[String: Any]]).count == 1)
        #expect(left["UserPromptSubmit"] == nil)
        #expect(left["PreToolUse"] == nil)
    }
}

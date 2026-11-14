import Foundation
import Testing
@testable import StewCore

private let session = SessionInfo(name: "deploy job", id: "s1", cwd: "/work/app")
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func permission(_ command: String = "deploy --token ghp_abcdefghijklmnopqrstuvwxyz0123456789") -> StewRequest { // gitleaks:allow (test fixture)
    StewRequest(session: session, prompt: .permission(PermissionRequest(action: "Deploy", command: command, reason: "release day")))
}

private func entry(_ outcome: HistoryEntry.Outcome, endedMinutesAgo minutes: Double, now: Date = start) -> HistoryEntry {
    HistoryEntry(
        received: now.addingTimeInterval(-minutes * 60 - 5), ended: now.addingTimeInterval(-minutes * 60),
        session: "s", cwd: nil, kind: "permission", summary: "x", command: nil, detail: nil, outcome: outcome
    )
}

@Suite struct HistoryRecordTests {
    @Test func masksTheCommandAndKeepsWhatClaudeWasTold() throws {
        let response = StewResponse(status: .timeout, note: "The user didn't respond within 1 min.")
        let recorded = HistoryEntry.record(permission(), received: start, response: response, ended: start.addingTimeInterval(60))
        #expect(recorded.command == "deploy --token ••••")
        #expect(recorded.summary == "Deploy")
        #expect(recorded.detail == "release day")
        #expect(recorded.session == "deploy job")
        #expect(recorded.cwd == "/work/app")
        #expect(recorded.outcome == .timedOut)
        #expect(recorded.missed)
        #expect(recorded.note == "The user didn't respond within 1 min.")
        let line = String(decoding: try History.line(recorded), as: UTF8.self)
        #expect(!line.contains("ghp_"))
        #expect(line.hasSuffix("\n"))
    }

    @Test func mapsEveryEnding() {
        let cases: [(StewResponse?, HistoryEntry.Outcome)] = [
            (StewResponse(status: .approved), .approved),
            (StewResponse(status: .denied), .denied),
            (StewResponse(status: .answered, answers: ["Q?": "A"]), .answered),
            (StewResponse(status: .acknowledged), .acknowledged),
            (StewResponse(status: .timeout), .timedOut),
            (StewResponse(status: .dismissed), .dismissed),
            (nil, .callerGone),
        ]
        for (response, expected) in cases {
            let recorded = HistoryEntry.record(permission("ls"), received: start, response: response, ended: start)
            #expect(recorded.outcome == expected)
            #expect(recorded.missed == (expected == .timedOut))
        }
    }

    @Test func questionsKeepTheAnswersAndEveryQuestion() {
        let set = QuestionSet(questions: [
            Question(question: "Which DB?", header: "DB", options: [QuestionOption(label: "Postgres", description: ""), QuestionOption(label: "SQLite", description: "")]),
            Question(question: "Which cache?", header: "Cache", options: [QuestionOption(label: "Redis", description: ""), QuestionOption(label: "None", description: "")]),
        ])
        let request = StewRequest(session: session, prompt: .question(set))
        let recorded = HistoryEntry.record(request, received: start, response: StewResponse(status: .answered, answers: ["Which DB?": "SQLite"]), ended: start)
        #expect(recorded.summary == "Which DB? (+1 more)")
        #expect(recorded.detail?.contains("  - Redis") == true)
        #expect(recorded.answers == ["Which DB?": "SQLite"])
    }

    @Test func keepsTheBlockedCallForAllowingLater() {
        let blocked = BlockedCall(toolName: "Bash", category: "Destructive", reason: "[Destructive]", hardDeny: false, projectRoot: "/work/app", suggestions: [])
        let request = StewRequest(session: session, prompt: .permission(PermissionRequest(action: "x", command: "rm -rf build", reason: "y", blocked: blocked)))
        #expect(HistoryEntry.record(request, received: start, response: nil, ended: start).blocked == blocked)
    }
}

@Suite struct HistoryFileTests {
    @Test func roundTripsAndSkipsBrokenLines() throws {
        let entries = [entry(.approved, endedMinutesAgo: 5), entry(.timedOut, endedMinutesAgo: 1)]
        var data = try History.lines(entries)
        data += Data("{\"half\":".utf8)
        #expect(History.parse(data) == entries)
    }

    @Test func prunesByAge() {
        let now = start
        let entries = [entry(.approved, endedMinutesAgo: 60 * 24 * 31, now: now), entry(.denied, endedMinutesAgo: 60 * 24 * 29, now: now), entry(.timedOut, endedMinutesAgo: 1, now: now)]
        #expect(History.pruned(entries, now: now, keepDays: 30).map(\.outcome) == [.denied, .timedOut])
        #expect(History.pruned(entries, now: now, keepDays: 0).isEmpty)
    }

    @Test func filtersMissedNewestFirst() {
        let entries = [entry(.timedOut, endedMinutesAgo: 9), entry(.dismissed, endedMinutesAgo: 5), entry(.timedOut, endedMinutesAgo: 1)]
        let missed = History.filtered(entries, missedOnly: true)
        #expect(missed.map(\.ended) == [entries[2].ended, entries[0].ended])
        #expect(History.filtered(entries, missedOnly: false).count == 3)
        #expect(History.missed(entries, since: start.addingTimeInterval(-6 * 60)).count == 1)
    }

    @Test func keepsThePickElseSelectsTheNewest() {
        let entries = [entry(.timedOut, endedMinutesAgo: 9), entry(.approved, endedMinutesAgo: 5), entry(.timedOut, endedMinutesAgo: 1)]
        let all = History.filtered(entries, missedOnly: false)
        let missed = History.filtered(entries, missedOnly: true)
        #expect(History.keptSelection(nil, in: all) == entries[2].id)
        #expect(History.keptSelection(entries[0].id, in: all) == entries[0].id)
        // The approved one is not missed: the newest missed one takes its place.
        #expect(History.keptSelection(entries[1].id, in: missed) == entries[2].id)
        #expect(History.keptSelection(entries[1].id, in: []) == nil)
    }

    @Test func summaryTitle() {
        #expect(History.returnSummary(missedCount: 1) == "1 request timed out while you were away")
        #expect(History.returnSummary(missedCount: 3) == "3 requests timed out while you were away")
    }

    @Test func historyDaysDefaultsToThirty() throws {
        #expect(StewConfig().historyDays == 30)
        #expect(try JSONDecoder().decode(StewConfig.self, from: Data(#"{"historyDays":7}"#.utf8)).historyDays == 7)
    }
}

@Suite struct AwayTrackerTests {
    @Test func reportsTheReturnAfterTwoMinutesIdle() {
        var tracker = AwayTracker()
        #expect(tracker.observe(idleSeconds: 30, now: start) == nil)
        #expect(tracker.observe(idleSeconds: 130, now: start) == nil)
        #expect(tracker.awaySince == start.addingTimeInterval(-130))
        #expect(tracker.observe(idleSeconds: 400, now: start.addingTimeInterval(270)) == nil)
        #expect(tracker.observe(idleSeconds: 1, now: start.addingTimeInterval(300)) == start.addingTimeInterval(-130))
        #expect(tracker.observe(idleSeconds: 1, now: start.addingTimeInterval(305)) == nil)
    }

    @Test func shortBreaksDoNotCount() {
        var tracker = AwayTracker()
        #expect(tracker.observe(idleSeconds: 119, now: start) == nil)
        #expect(tracker.observe(idleSeconds: 0, now: start) == nil)
    }
}

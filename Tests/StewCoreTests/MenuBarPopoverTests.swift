import Foundation
import Testing
@testable import StewCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func entry(_ outcome: HistoryEntry.Outcome, minutes: Double) -> HistoryEntry {
    HistoryEntry(
        received: start, ended: start.addingTimeInterval(minutes * 60), session: "s", cwd: nil, kind: "permission",
        summary: "\(outcome.rawValue) \(Int(minutes))", command: nil, detail: nil, outcome: outcome
    )
}

@Suite struct MenuBarPopoverContentTests {
    private let needs = [NeedsItem(id: "n1", created: start, session: SessionInfo(name: "s"), needs: NeedsRequest(title: "Log in"))]
    private let entries = [entry(.approved, minutes: 1), entry(.timedOut, minutes: 2), entry(.later, minutes: 3), entry(.denied, minutes: 4)]

    @Test func listsNeedsThenTheNewestRequests() {
        let content = MenuBarPopoverContent(state: MenuBarState(openNeeds: needs), entries: entries, missedOnly: false)
        #expect(content.needs.map(\.id) == ["n1"])
        #expect(content.history.map(\.summary) == ["denied 4", "later 3", "timedOut 2", "approved 1"])
        #expect(content.historyTotal == 4)
    }

    @Test func missedOnlyKeepsWhatCanStillBeAnswered() {
        let content = MenuBarPopoverContent(state: MenuBarState(), entries: entries, missedOnly: true)
        #expect(content.history.map(\.summary) == ["later 3", "timedOut 2"])
    }

    @Test func stopsAtTheLimit() {
        let content = MenuBarPopoverContent(state: MenuBarState(), entries: entries, missedOnly: false, limit: 2)
        #expect(content.history.count == 2)
        #expect(content.historyTotal == 4)
    }

    @Test func marksMissedSeenOnlyWhenTheListShows() {
        #expect(MenuBarPopoverContent(state: MenuBarState(), entries: entries, missedOnly: false).marksMissedSeen)
        let onlyNeeds = MenuBarPopoverContent(state: MenuBarState(openNeeds: needs), entries: [], missedOnly: false)
        #expect(!onlyNeeds.marksMissedSeen)
        #expect(!onlyNeeds.isEmpty)
        let nothingMissed = MenuBarPopoverContent(state: MenuBarState(), entries: [entry(.approved, minutes: 1)], missedOnly: true)
        #expect(!nothingMissed.marksMissedSeen)
        #expect(nothingMissed.isEmpty)
    }
}

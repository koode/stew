import Foundation

/// What the menu bar popover lists: the open needs items first, then the most recent
/// finished requests, or only the missed ones.
public struct MenuBarPopoverContent: Equatable, Sendable {
    /// How many finished requests the popover lists; History has the rest.
    public static let historyLimit = 25

    public var needs: [NeedsItem]
    public var history: [HistoryEntry]
    /// Every finished request the filter lets through, also those past the limit.
    public var historyTotal: Int

    public init(state: MenuBarState, entries: [HistoryEntry], missedOnly: Bool, limit: Int = historyLimit) {
        needs = state.openNeeds
        let filtered = History.filtered(entries, missedOnly: missedOnly)
        history = Array(filtered.prefix(max(limit, 0)))
        historyTotal = filtered.count
    }

    public var isEmpty: Bool { needs.isEmpty && history.isEmpty }

    /// Opening the popover counts as seeing the missed requests, the same as opening
    /// History, but only when its list of requests shows: with nothing in it, the user
    /// saw nothing.
    public var marksMissedSeen: Bool { !history.isEmpty }
}

import Foundation

/// What the menu bar popover lists: the open needs items first, then every finished
/// request, newest first, or only the missed ones.
public struct MenuBarPopoverContent: Equatable, Sendable {
    public var needs: [NeedsItem]
    public var history: [HistoryEntry]

    public init(state: MenuBarState, entries: [HistoryEntry], missedOnly: Bool) {
        needs = state.openNeeds
        history = History.filtered(entries, missedOnly: missedOnly)
    }

    public var isEmpty: Bool { needs.isEmpty && history.isEmpty }

    /// Opening the popover counts as seeing the missed requests, the same as opening
    /// History, but only when its list of requests shows: with nothing in it, the user
    /// saw nothing.
    public var marksMissedSeen: Bool { !history.isEmpty }
}

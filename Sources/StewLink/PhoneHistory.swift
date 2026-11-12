import Foundation
import StewCore

/// One request as the phone remembers it. Text that may hold secrets is masked before it
/// is stored, the same way the Mac masks commands, so history never keeps a secret.
public struct PhoneHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { pairingId + "/" + requestId }
    public var pairingId: String
    public var requestId: String
    public var macName: String
    public var sessionName: String
    public var kindTitle: String
    public var kindSymbol: String
    /// The action, question or notification title.
    public var summary: String
    public var command: String?
    public var receivedAt: Date
    public var deadline: Date?
    public var resolvedAt: Date?
    /// Nil while the request is still open.
    public var outcome: LinkOutcome?

    public init(pairingId: String, request: LinkRequest) {
        self.pairingId = pairingId
        requestId = request.requestId
        macName = request.macName
        sessionName = request.request.session.name
        kindTitle = LinkPresentation.kindTitle(request.request.prompt)
        kindSymbol = LinkPresentation.kindSymbol(request.request.prompt)
        switch request.request.prompt {
        case .permission(let permission):
            summary = CommandText.masked(permission.action)
            command = permission.command.flatMap { $0.isEmpty ? nil : CommandText.masked($0) }
        case .question(let set):
            summary = CommandText.masked(set.questions.map(\.question).joined(separator: " · "))
        case .notify(let notify):
            summary = CommandText.masked(notify.title)
        case .needs(let needs):
            summary = CommandText.masked(needs.title)
            command = needs.commands.isEmpty ? nil : needs.commands.map { CommandText.masked($0.command) }.joined(separator: "\n")
        }
        receivedAt = request.receivedAt
        deadline = request.deadline
    }
}

/// The phone's short history, kept in the app group so the app and the notification
/// extension share it.
public struct PhoneHistory: Codable, Equatable, Sendable {
    public static let defaultRetention: TimeInterval = 30 * 24 * 3600

    public private(set) var entries: [PhoneHistoryEntry] = []

    public init(entries: [PhoneHistoryEntry] = []) {
        self.entries = entries
    }

    /// Adds a request, or refreshes its deadline when the Mac sent an update.
    public mutating func record(_ request: LinkRequest, pairingId: String) {
        if let index = entries.firstIndex(where: { $0.pairingId == pairingId && $0.requestId == request.requestId }) {
            entries[index].deadline = request.deadline
            return
        }
        entries.append(PhoneHistoryEntry(pairingId: pairingId, request: request))
    }

    /// The first outcome sticks: the Mac's resolution and the phone's own answer may
    /// both arrive, and they agree when both are right.
    public mutating func resolve(requestId: String, pairingId: String, outcome: LinkOutcome, at date: Date) {
        guard let index = entries.firstIndex(where: { $0.pairingId == pairingId && $0.requestId == requestId }),
              entries[index].outcome == nil else { return }
        entries[index].outcome = outcome
        entries[index].resolvedAt = date
    }

    /// A request whose deadline passed with no outcome is missed, even when the Mac's
    /// "resolved" push never arrived.
    public mutating func markOverdue(now: Date) {
        for index in entries.indices where entries[index].outcome == nil {
            if let deadline = entries[index].deadline, deadline < now {
                entries[index].outcome = .timedOut
                entries[index].resolvedAt = deadline
            }
        }
    }

    public mutating func prune(now: Date, retention: TimeInterval = PhoneHistory.defaultRetention) {
        entries.removeAll { now.timeIntervalSince($0.receivedAt) > retention }
    }

    public mutating func removeAll(pairingId: String) {
        entries.removeAll { $0.pairingId == pairingId }
    }

    public var open: [PhoneHistoryEntry] {
        entries.filter { $0.outcome == nil }.sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Closed requests, newest first.
    public func closed(missedOnly: Bool) -> [PhoneHistoryEntry] {
        entries
            .filter { entry in
                guard let outcome = entry.outcome else { return false }
                return !missedOnly || outcome.isMissed
            }
            .sorted { $0.receivedAt > $1.receivedAt }
    }
}

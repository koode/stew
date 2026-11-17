import Foundation

/// Signing in, as a state machine the settings pane drives: the user types an address,
/// the server emails a code and a link, and the Mac polls for the link's approval while
/// it also takes the code. Results for a sign-in the user already left are ignored.
public struct SignInFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case enterEmail
        case sending
        /// The email went out; the Mac polls and takes the code.
        case waiting(SignInStart)
        /// A code is on its way to the server; polling goes on.
        case checkingCode(SignInStart)
    }

    /// How often the Mac asks whether the link was approved.
    public static let pollInterval: TimeInterval = 2

    public var email: String
    public private(set) var phase: Phase = .enterEmail
    /// Why the last step failed, shown under the field or the code.
    public private(set) var problem: AccountError?
    /// The address the email went to, for "Check your email".
    public private(set) var sentTo: String?
    /// The last code sent to the server, so only a changed code clears "not right".
    public private(set) var checkedCode: String?
    /// When the pending sign-in expires on this Mac's clock: the time it arrived plus the
    /// time the server said it had left. Nil when the server sent no Date header; its 410
    /// then ends the sign-in.
    public private(set) var localDeadline: Date?

    public init(email: String = "") {
        self.email = email
    }

    /// The pending sign-in, while there is one.
    public var pending: SignInStart? {
        switch phase {
        case .waiting(let start), .checkingCode(let start): start
        case .enterEmail, .sending: nil
        }
    }

    public var shouldPoll: Bool { pending != nil }
    public var isCheckingCode: Bool { if case .checkingCode = phase { true } else { false } }
    /// The server takes no more codes for this address today; only the link signs in.
    public var codesLocked: Bool { problem == .codesLocked }

    public var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A cheap check before asking the server, which decides: one @ with text on both
    /// sides, a dot in the domain, and no spaces.
    public static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !text.contains(where: \.isWhitespace) else { return false }
        return true
    }

    public var canSend: Bool { phase == .enterEmail && Self.looksLikeEmail(trimmedEmail) }

    /// Starts sending; returns the address to send to, or nil when it cannot go.
    public mutating func send() -> String? {
        guard canSend else { return nil }
        phase = .sending
        problem = nil
        return trimmedEmail
    }

    public mutating func sent(_ result: Result<SignInStart, AccountError>, now: Date = Date()) {
        guard phase == .sending else { return }
        switch result {
        case .success(let start):
            phase = .waiting(start)
            sentTo = trimmedEmail
            localDeadline = start.lifetime.map { now.addingTimeInterval($0) }
            problem = nil
        case .failure(let error):
            phase = .enterEmail
            problem = error
        }
    }

    /// Shows a problem found before any call, such as a bad server address.
    public mutating func reportProblem(_ error: AccountError) {
        problem = error
    }

    /// The code field changed: a note that the last code was wrong no longer applies once
    /// the code differs from it.
    public mutating func codeChanged(to code: String) {
        if case .wrongCode = problem, code != checkedCode { problem = nil }
    }

    /// Back to the address field, dropping the pending sign-in.
    public mutating func useAnotherEmail() {
        phase = .enterEmail
        problem = nil
        sentTo = nil
        checkedCode = nil
        localDeadline = nil
    }

    /// Starts checking a code; returns the sign-in to send it with, or nil when the code
    /// is not six digits or no sign-in waits.
    public mutating func checkCode(_ code: String) -> SignInStart? {
        guard case .waiting(let start) = phase, !codesLocked, code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        phase = .checkingCode(start)
        problem = nil
        checkedCode = code
        return start
    }

    /// Applies a poll's result. Returns the session when the link was approved.
    public mutating func polled(_ start: SignInStart, _ result: Result<SignInPoll, AccountError>) -> SignedIn? {
        guard pending?.signInId == start.signInId else { return nil }
        switch result {
        case .success(.approved(let signedIn)):
            finish()
            return signedIn
        case .success(.pending):
            // A poll that got through clears an offline notice from an earlier one.
            if problem?.isTransient == true { problem = nil }
            return nil
        case .failure(.expired):
            expire()
            return nil
        case .failure(let error):
            // Offline or a passing server error: keep polling, and say so. A refused code
            // stays on screen until the next code.
            if problem?.isCodeProblem != true { problem = error }
            return nil
        }
    }

    /// Applies the answer to a code. Returns the session when the code was right.
    public mutating func codeChecked(_ start: SignInStart, _ result: Result<SignedIn, AccountError>) -> SignedIn? {
        guard pending?.signInId == start.signInId else { return nil }
        switch result {
        case .success(let signedIn):
            finish()
            return signedIn
        case .failure(.expired):
            expire()
            return nil
        case .failure(let error):
            phase = .waiting(start)
            problem = error
            return nil
        }
    }

    /// The sign-in ran past its expiry without an answer. Measured from when it arrived,
    /// never against the server's time, so a Mac clock that runs ahead cannot end it early.
    public mutating func tick(now: Date) {
        guard pending != nil, let localDeadline, now >= localDeadline else { return }
        expire()
    }

    private mutating func expire() {
        phase = .enterEmail
        problem = .expired
        sentTo = nil
        checkedCode = nil
        localDeadline = nil
    }

    private mutating func finish() {
        phase = .enterEmail
        problem = nil
        sentTo = nil
        checkedCode = nil
        localDeadline = nil
    }
}

/// Waiting for a checkout in the browser: the Mac asks for the account every few seconds
/// for a while, until the plan shows as paid.
public struct PaymentWait: Equatable, Sendable {
    public static let pollInterval: TimeInterval = 5
    public static let longest: TimeInterval = 10 * 60

    public enum Step: Equatable, Sendable {
        case keepWaiting, paid, gaveUp
    }

    public let startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Paid: an active plan that renews. Offers show only while that is not so, so any
    /// checkout started from one ends here.
    public static func isPaid(_ account: Account) -> Bool {
        account.plan.status == .active && !account.plan.cancelAtPeriodEnd
    }

    public func step(account: Account?, now: Date) -> Step {
        if let account, Self.isPaid(account) { return .paid }
        return now.timeIntervalSince(startedAt) >= Self.longest ? .gaveUp : .keepWaiting
    }
}

/// Which session the Mac is in. A call takes the generation when it starts, and its result
/// counts only while that is still current: a refresh that comes back after a sign-out, a
/// deletion or a new sign-in must not bring back the session it started in, nor send its
/// lease on.
public struct AccountSessionGeneration: Equatable, Sendable {
    public private(set) var current = 0

    public init() {}

    /// A session ended or began.
    public mutating func advance() {
        current += 1
    }

    public func isCurrent(_ started: Int) -> Bool {
        started == current
    }
}

/// When the Mac asks for the account again on its own.
public enum AccountRefresh {
    /// At launch, then once a day, so a renewed plan reaches the relay before its lease
    /// runs out.
    public static let interval: TimeInterval = 24 * 3600

    public static func isDue(lastRefresh: Date?, now: Date) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= interval
    }
}

/// Whether to send the account's lease to one pairing's relay.
public enum LeaseForwarding {
    public enum Decision: Equatable, Sendable {
        case send
        /// Signed out, or no plan: nothing to send.
        case noLease
        /// The relay does not say `"leases": true` in /v2/info, or is not v2.
        case relayWithoutLeases
        /// This exact lease already reached this pairing.
        case alreadySent
    }

    public static func decide(lease: String?, relayAcceptsLeases: Bool, lastSent: String?) -> Decision {
        guard let lease, !lease.isEmpty else { return .noLease }
        guard relayAcceptsLeases else { return .relayWithoutLeases }
        return lease == lastSent ? .alreadySent : .send
    }

    /// Whether to send the lease once more after the relay stopped a pairing for want of
    /// a plan. The lease may have reached the relay just before the refusal, so the link
    /// would otherwise stay stopped; once per lease, so a relay that keeps refusing gets
    /// no loop.
    public static func retryAfterPlanStop(lease: String?, lastRetried: String?) -> Bool {
        guard let lease, !lease.isEmpty else { return false }
        return lease != lastRetried
    }

    /// The lease to put in a claim body: only for a relay that takes leases.
    public static func claimLease(_ lease: String?, relayAcceptsLeases: Bool) -> String? {
        guard relayAcceptsLeases, let lease, !lease.isEmpty else { return nil }
        return lease
    }
}

/// How the pane shows a plan: its name, a status pill, and a line under it.
public struct AccountPlanSummary: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case good, attention, neutral
    }

    public var name: String
    public var status: String
    public var tone: Tone
    public var hint: String
    /// Whether billing has something to manage: the account paid at some point.
    public var hasBilling: Bool
    /// The line under the offers.
    public var subscribeHint = "Checkout opens in your browser."

    /// Days left, counted up: 30 hours is 2 days.
    public static func daysLeft(until end: Date, now: Date) -> Int {
        max(0, Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    public init(plan: AccountPlan, now: Date, dateText: (Date) -> String) {
        var plan = plan
        let liveGift = plan.giftEndsAt.map { $0 > now } ?? (plan.status == .gift)
        /// When the trial or the paid period ends, whichever is later.
        let otherEnd = [plan.trialEndsAt, plan.currentPeriodEnd].compactMap { $0 }.max()
        // The gift is what ended when it was the last thing that entitled: it shows as the
        // gift with its end date, not as the trial or plan from before it.
        let endedGift = plan.giftEndsAt.flatMap { giftEnd in
            giftEnd <= now && (plan.status == .gift || (plan.status == .expired && giftEnd >= (otherEnd ?? .distantPast))) ? giftEnd : nil
        }
        if plan.status == .gift, !liveGift { plan.status = .expired }
        let paidName: String
        switch plan.interval {
        case .month: paidName = "stew Pro, monthly"
        case .year: paidName = "stew Pro, yearly"
        case .other, nil: paidName = "stew Pro"
        }
        hasBilling = plan.interval != nil || [.active, .pastDue, .canceled].contains(plan.status)
        let periodEnd = plan.currentPeriodEnd
        switch plan.status {
        case .trial:
            name = "Trial"
            if let end = plan.trialEndsAt, end > now {
                let days = Self.daysLeft(until: end, now: now)
                status = "\(days) \(days == 1 ? "day" : "days") left"
                tone = days <= 3 ? .attention : .good
                hint = "The trial ends \(dateText(end)). Subscribe to keep the iPhone relay after that."
            } else {
                status = "Expired"
                tone = .attention
                hint = "Subscribe to use the iPhone relay again."
            }
        case .active where plan.cancelAtPeriodEnd:
            name = paidName
            status = "Not renewing"
            tone = .attention
            hint = periodEnd.map { "Ends \(dateText($0)). Subscribe again to keep the iPhone relay after that." }
                ?? "Ends at the end of this period."
        case .active:
            name = paidName
            status = "Active"
            tone = .good
            hint = periodEnd.map { "Renews \(dateText($0))." } ?? "Renews automatically."
        case .pastDue:
            name = paidName
            status = "Payment problem"
            tone = .attention
            hint = "The last payment did not go through. Update the payment method in Manage billing to keep the iPhone relay."
        case .canceled:
            name = paidName
            if let periodEnd, periodEnd > now {
                status = "Canceled"
                tone = .attention
                hint = "Ends \(dateText(periodEnd)). Subscribe again to keep the iPhone relay after that."
            } else {
                status = "Expired"
                tone = .attention
                hint = "Subscribe to use the iPhone relay again."
            }
        case .expired:
            status = "Expired"
            tone = .attention
            if let endedGift {
                name = "stew Pro (gift)"
                hint = "Ended \(dateText(endedGift)). Subscribe to use the iPhone relay again."
            } else {
                name = plan.interval == nil ? "Trial" : paidName
                hint = "Subscribe to use the iPhone relay again."
            }
        case .gift:
            name = "stew Pro (gift)"
            status = "Active"
            tone = .good
            hint = plan.giftEndsAt.map { "Gift ends \(dateText($0))." } ?? "The gift has no end date."
            subscribeHint = "Subscribe to keep stew Pro after the gift ends."
        case .other(let raw):
            name = paidName
            status = raw.replacingOccurrences(of: "_", with: " ").capitalized
            tone = .neutral
            hint = "Update stew to see more about this plan."
        }
        // A gift beside a trial or a paid plan: that plan shows, and the gift only when it
        // reaches past the trial and the paid period.
        if plan.status != .gift, liveGift, let giftEnd = plan.giftEndsAt, giftEnd > (otherEnd ?? .distantPast) {
            hint += "\nGift until \(dateText(giftEnd))."
        }
    }
}

import Foundation

/// What a severity level changes about a permission request. Low and medium change
/// nothing; the risk check being off or failing means no severity, so nothing either.
public enum SeverityRules {
    /// Values of `ClassifierConfig.phoneConfirmation`.
    public enum PhoneScope {
        public static let highAndCritical = "highAndCritical"
        public static let critical = "critical"
        public static let off = "off"
    }

    /// Critical needs the stronger approve shortcut (⇧⌘↩ by default), like a hard deny.
    public static func needsStrongApprove(_ severity: Severity?, config: StewConfig.ClassifierConfig) -> Bool {
        severity == .critical && config.criticalNeedsStrongApprove
    }

    /// Seconds added to the time to answer: high and critical get time to read first.
    public static func extraTime(_ severity: Severity?, config: StewConfig.ClassifierConfig) -> Double {
        guard let severity, severity >= .high else { return 0 }
        return max(0, config.highExtraTime)
    }

    /// High and critical take the warning look in the panel.
    public static func warns(_ severity: Severity?) -> Bool {
        guard let severity else { return false }
        return severity >= .high
    }

    /// The step the iPhone asks for before it approves: a sheet for high, a held button
    /// for critical. Nil when the level or the setting asks for none.
    public static func phoneConfirmation(_ severity: Severity?, config: StewConfig.ClassifierConfig) -> PhoneConfirmation? {
        guard let severity, severity >= .high else { return nil }
        switch config.phoneConfirmation {
        case PhoneScope.off:
            return nil
        case PhoneScope.critical:
            return severity == .critical ? .hold : nil
        default:
            return severity == .critical ? .hold : .confirm
        }
    }

    /// Whether the Mac takes an approval from the phone: one for a request that needs an
    /// extra confirmation must say the phone asked for it. A phone app from before
    /// severity never says so, so it cannot approve such a request.
    public static func acceptsPhoneApproval(confirmation: PhoneConfirmation?, confirmed: Bool?) -> Bool {
        confirmation == nil || confirmed == true
    }
}

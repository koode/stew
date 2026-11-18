import AppKit
import SwiftUI
import StewCore
import StewLink

/// Renders Settings ▸ iPhone in each pairing state, for `stew snapshot`. It never touches
/// the keychain or the network.
enum PhoneSnapshot {
    private struct Scenario {
        let name: String
        var pairings: [MacPairing] = []
        var statuses: [String: RelayConnection.Status] = [:]
        var code: PairingCode?
        var error: String?
        var plan: RelayPlanRequired?
        var sample = PhonePaneSample()
        /// phone.relay as config.json sets it; nil keeps the default.
        var relay: String?
        /// Tall enough to show the relay row at the bottom of the pane.
        var tall = false
        /// The relay needs a plan to pair (`plans` in GET /v2/info).
        var relayRequiresPlan = false
        /// The signed-in account, nil when signed out.
        var account: Account?
    }

    static func render(to directory: String, write: (AnyView, Bool, String) -> Void) {
        let identity = LinkIdentity()
        let store = PhoneStore(sampleIdentity: identity)
        let created = Date(timeIntervalSince1970: 1_794_000_000)
        func pairing(_ id: String, _ state: MacPairing.State, phone: String?, created: Date, paired: Date? = nil) -> MacPairing {
            MacPairing(
                pairingId: id, relay: PhoneConfig.defaultRelay, macName: "Studio", secret: LinkRandom.bytes(32),
                state: state, phoneName: phone, phoneKeys: phone == nil ? nil : LinkIdentity().publicKeys, createdAt: created, pairedAt: paired
            )
        }
        let paired = pairing("samplepaired", .paired, phone: "Jamie's iPhone", created: created, paired: created)
        let second = pairing("samplesecond", .paired, phone: "Work iPhone", created: created.addingTimeInterval(86_400 * 9), paired: created.addingTimeInterval(86_400 * 9))
        let confirming = pairing("sampleconfirm", .confirming, phone: "Work iPhone", created: created)
        let code = PairingCode.generate(relay: PhoneConfig.defaultRelay, macName: "Studio", macKeys: identity.publicKeys)
        // The Mac shows the code 2 minutes 19 seconds after it made it: 7:41 left.
        let waiting = MacPairing(
            pairingId: code.pairingId, relay: code.relay, macName: code.macName, secret: code.secret,
            state: .waiting, createdAt: Date().addingTimeInterval(-139)
        )
        let connected: [String: RelayConnection.Status] = ["samplepaired": .connected, "samplesecond": .failed("offline")]
        let expired = Account(
            id: "acc_sample", email: "jamie@example.com",
            plan: AccountPlan(status: .expired, trialEndsAt: created.addingTimeInterval(-3 * 86_400)), entitled: false
        )
        let samplePlan = RelayPlanRequired(message: "A second iPhone needs a stew plan.", upgradeURL: "https://stewcli.com/plans")
        let scenarios = [
            Scenario(name: "empty"),
            Scenario(name: "pairing", pairings: [waiting], code: code),
            Scenario(name: "confirm", pairings: [paired, confirming], statuses: connected),
            Scenario(name: "mismatch", pairings: [confirming], sample: PhonePaneSample(digits: "418207", mismatch: true)),
            Scenario(name: "error", error: "Cannot reach the relay at \(PhoneConfig.defaultRelay)."),
            Scenario(name: "paired", pairings: [paired, second], statuses: connected, sample: PhonePaneSample(justPaired: "Work iPhone")),
            Scenario(name: "plan", pairings: [paired, second], statuses: ["samplepaired": .connected, "samplesecond": .stopped(.planRequired(samplePlan))]),
            Scenario(name: "plan-pairing", plan: samplePlan),
            Scenario(name: "pro-signed-out", relayRequiresPlan: true),
            Scenario(name: "pro-expired", pairings: [paired], statuses: ["samplepaired": .stopped(.planRequired(samplePlan))], relayRequiresPlan: true, account: expired),
            Scenario(name: "relay", pairings: [paired], statuses: connected, tall: true),
            Scenario(name: "relay-own", pairings: [paired], statuses: connected, relay: "http://localhost:4000", tall: true),
        ]
        let link = PhoneLink.shared
        for scenario in scenarios {
            let relayPlans = scenario.relayRequiresPlan ? [scenario.relay ?? PhoneConfig.defaultRelay: true] : [:]
            link.showSample(
                pairings: scenario.pairings, statuses: scenario.statuses, code: scenario.code, error: scenario.error, plan: scenario.plan,
                relayRequiresPlan: relayPlans, store: store
            )
            AccountModel.shared.showSample(account: scenario.account)
            for dark in [false, true] {
                let model = SettingsModel()
                model.load()
                if let relay = scenario.relay { model.showSample { $0.phone.relay = relay } }
                model.tab = .phone
                let path = "\(directory)/settings-phone-\(scenario.name)-\(dark ? "dark" : "light").png"
                let view = SettingsView(
                    model: model, approvals: ApprovalsModel(), history: HistoryModel(), updater: Updater(log: { _ in }), phoneSample: scenario.sample
                )
                write(AnyView(view.frame(width: Snapshot.settingsSize.width, height: scenario.tall ? 760 : Snapshot.settingsSize.height)), dark, path)
                print(path)
                // Also in the window as wide as History makes it.
                if scenario.name == "paired" {
                    let widePath = "\(directory)/settings-phone-\(scenario.name)-wide-\(dark ? "dark" : "light").png"
                    write(AnyView(view.frame(width: SettingsWindowController.historyWidth, height: Snapshot.settingsSize.height)), dark, widePath)
                    print(widePath)
                }
            }
        }
    }
}

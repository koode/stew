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
        var sample = PhonePaneSample()
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
        let scenarios = [
            Scenario(name: "empty"),
            Scenario(name: "pairing", pairings: [waiting], code: code),
            Scenario(name: "confirm", pairings: [paired, confirming], statuses: connected),
            Scenario(name: "mismatch", pairings: [confirming], sample: PhonePaneSample(digits: "418207", mismatch: true)),
            Scenario(name: "error", error: "Cannot reach the relay at \(PhoneConfig.defaultRelay)."),
            Scenario(name: "paired", pairings: [paired, second], statuses: connected, sample: PhonePaneSample(justPaired: "Work iPhone")),
        ]
        let link = PhoneLink.shared
        for scenario in scenarios {
            link.showSample(pairings: scenario.pairings, statuses: scenario.statuses, code: scenario.code, error: scenario.error, store: store)
            for dark in [false, true] {
                let model = SettingsModel()
                model.load()
                model.tab = .phone
                let path = "\(directory)/settings-phone-\(scenario.name)-\(dark ? "dark" : "light").png"
                let view = SettingsView(
                    model: model, approvals: ApprovalsModel(), history: HistoryModel(), updater: Updater(log: { _ in }), phoneSample: scenario.sample
                )
                write(AnyView(view.frame(width: Snapshot.settingsSize.width, height: Snapshot.settingsSize.height)), dark, path)
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

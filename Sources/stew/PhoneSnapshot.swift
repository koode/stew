import AppKit
import SwiftUI
import StewCore
import StewLink

/// Renders Settings ▸ iPhone with sample pairings, for `stew snapshot`. It never touches
/// the keychain or the network.
enum PhoneSnapshot {
    static func render(to directory: String, write: (AnyView, Bool, String) -> Void) {
        let identity = LinkIdentity()
        let store = PhoneStore(sampleIdentity: identity)
        let created = Date(timeIntervalSince1970: 1_794_000_000)
        let paired = MacPairing(
            pairingId: "samplepaired", relay: PhoneConfig.defaultRelay, macName: "Studio", secret: LinkRandom.bytes(32),
            state: .paired, phoneName: "Jamie's iPhone", phoneKeys: LinkIdentity().publicKeys, createdAt: created, pairedAt: created
        )
        let confirming = MacPairing(
            pairingId: "sampleconfirm", relay: PhoneConfig.defaultRelay, macName: "Studio", secret: LinkRandom.bytes(32),
            state: .confirming, phoneName: "Work iPhone", phoneKeys: LinkIdentity().publicKeys, createdAt: created
        )
        let code = PairingCode.generate(relay: PhoneConfig.defaultRelay, macName: "Studio", macKeys: identity.publicKeys)
        let scenarios: [(String, [MacPairing], PairingCode?)] = [
            ("pairing", [], code),
            ("confirm", [paired, confirming], nil),
        ]
        let link = PhoneLink.shared
        for (name, pairings, shownCode) in scenarios {
            link.showSample(pairings: pairings, statuses: ["samplepaired": .connected], code: shownCode, store: store)
            for dark in [false, true] {
                let model = SettingsModel()
                model.load()
                model.tab = .phone
                let path = "\(directory)/settings-phone-\(name)-\(dark ? "dark" : "light").png"
                write(AnyView(SettingsView(model: model, approvals: ApprovalsModel(), history: HistoryModel(), updater: Updater(log: { _ in })).frame(width: 720, height: 640)), dark, path)
                print(path)
            }
        }
    }
}

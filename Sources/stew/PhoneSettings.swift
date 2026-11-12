import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import StewCore
import StewLink

/// Settings ▸ iPhone: pair phones, see and unpair them, and choose when requests go there.
struct PhoneSettingsTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var link: PhoneLink
    @State private var unpairing: MacPairing?

    private static let modes: [(String, PhonePushMode)] = [("When I'm away", .away), ("Always", .always), ("Never", .never)]
    private static let waits: [(String, Double)] = [("10 seconds", 10), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120)]

    var body: some View {
        Form {
            Section("iPhones") {
                if link.paired.isEmpty && link.pairingCode == nil && link.confirming == nil {
                    Text("No iPhone is paired yet.").foregroundStyle(.secondary)
                }
                ForEach(link.paired) { pairing in
                    PairedPhoneRow(pairing: pairing, status: link.statuses[pairing.pairingId]) { unpairing = pairing }
                }
                if let confirming = link.confirming {
                    ConfirmPairing(pairing: confirming, link: link)
                } else if let code = link.pairingCode {
                    PairingCodeView(code: code) { link.cancelPairing() }
                } else {
                    SettingRow(hint: "Requests that stay open while you are away arrive as notifications you can answer. Everything is end-to-end encrypted; the relay cannot read requests or answers.") {
                        Button("Pair an iPhone…") { link.startPairing() }
                    }
                }
                if let error = link.pairingError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Section("Sending") {
                SettingRow(hint: "Away means no keyboard or mouse input for \(Self.minutes(model.config.phone.idleAfter)), or a locked screen. Someone at the Mac answers in the panel.") {
                    Picker("Send requests", selection: Binding(
                        get: { model.config.phone.mode },
                        set: { value in model.update { $0.phone.push = value.rawValue } }
                    )) {
                        ForEach(Self.modes, id: \.1) { Text($0.0).tag($0.1) }
                    }
                }
                SettingRow(hint: "A request goes to your iPhone only after it has been open this long. The time to answer still applies there.") {
                    Picker("Wait before sending", selection: Binding(
                        get: { model.config.phone.after },
                        set: { value in model.update { $0.phone.after = value } }
                    )) {
                        ForEach(Self.waits, id: \.1) { Text($0.0).tag($0.1) }
                    }
                }
                SettingRow(hint: "Used for new pairings. To run your own relay, set phone.relay in config.json.") {
                    LabeledContent("Relay") {
                        Text(model.config.phone.relay).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Unpair \(unpairing?.phoneName ?? "this iPhone")?",
            isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }),
            presenting: unpairing
        ) { pairing in
            Button("Unpair", role: .destructive) { link.unpair(pairing.pairingId) }
        } message: { _ in
            Text("Requests stop going to this iPhone, and it removes this Mac.")
        }
    }

    static func minutes(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

struct PairedPhoneRow: View {
    let pairing: MacPairing
    let status: RelayConnection.Status?
    let onUnpair: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(pairing.phoneName ?? "iPhone").font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unpair", action: onUnpair)
        }
    }

    private var detail: String {
        let paired = "Paired \((pairing.pairedAt ?? pairing.createdAt).formatted(date: .abbreviated, time: .omitted))"
        switch status {
        case .connected: return paired + " · Connected"
        case .failed: return paired + " · Relay unreachable, retrying"
        case .connecting, nil: return paired + " · Connecting…"
        }
    }
}

/// The QR code, and the same code as text to copy, while the Mac waits for a phone.
struct PairingCodeView: View {
    let code: PairingCode
    let onCancel: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            if let image = Self.qrImage(code.text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Scan with the stew app").font(.system(size: 13, weight: .semibold))
                Text("On your iPhone, open stew, tap Pair a Mac and point the camera at this code.")
                    .fixedSize(horizontal: false, vertical: true)
                SettingRow(hint: copied ? "Copied for 1 minute. Paste it in the stew app on your iPhone." : "Universal Clipboard brings it to your iPhone, where you can paste it instead of scanning. The code works for 10 minutes.") {
                    Button("Copy code") { copy() }
                }
                Button("Cancel", action: onCancel)
            }
            .font(.system(size: 12))
        }
        .padding(.vertical, 6)
    }

    /// Marked concealed and transient, so clipboard managers skip it, and cleared after a
    /// minute: the code holds the pairing secret.
    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(code.text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        let written = pasteboard.changeCount
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if pasteboard.changeCount == written { pasteboard.clearContents() }
        }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// A phone has registered with the code. The user types the digits the phone shows; the
/// Mac never shows them itself, so they can only come from the phone. Until then the
/// phone's answers are ignored.
struct ConfirmPairing: View {
    let pairing: MacPairing
    @ObservedObject var link: PhoneLink
    @State private var digits = ""
    @State private var mismatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(pairing.phoneName ?? "An iPhone") wants to pair").font(.system(size: 13, weight: .semibold))
            SettingRow(hint: mismatch
                ? "These digits do not match. Check your iPhone again, or reject if it shows none."
                : "Type the six digits your iPhone shows. If it shows none, reject: someone else may have used the code.") {
                TextField("Code", text: $digits, prompt: Text("Six digits"))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .onSubmit(confirm)
                    .onChange(of: digits) { mismatch = false }
            }
            HStack {
                Button("Reject") { link.unpair(pairing.pairingId) }
                Button("Confirm", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(digits.filter(\.isNumber).count != 6)
            }
        }
        .padding(.vertical, 6)
    }

    private func confirm() {
        mismatch = !link.confirm(pairing.pairingId, digits: digits)
    }
}

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import StewCore
import StewLink

/// The iPhone pane's own state that `stew snapshot` sets: a phone just paired, or digits
/// typed in the confirmation.
struct PhonePaneSample {
    var justPaired: String?
    var digits = ""
    var mismatch = false
}

/// Settings ▸ iPhone: pair phones, see and unpair them, and choose when requests go there.
struct PhoneSettingsTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var link: PhoneLink
    @State private var unpairing: MacPairing?
    /// The phone that was just confirmed, for the success message.
    @State private var justPaired: String?

    private static let modes: [(String, PhonePushMode)] = [("When I'm away", .away), ("Always", .always), ("Never", .never)]
    private static let viewingCaps: [(String, Double)] = [("5 minutes", 300), ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600)]
    private static let awayAfters: [(String, Double)] = [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900)]
    /// An offered relay by its host: "relay.stewcli.com".
    private static func relayName(_ relay: String) -> String {
        URL(string: relay)?.host ?? relay
    }

    private static let waits: [(String, Double)] = [("Instantly", 0), ("3 seconds", 3), ("5 seconds", 5), ("10 seconds", 10), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120)]
    private static let pairHint = "Requests that stay open while you are away arrive as notifications you can answer. Everything is end-to-end encrypted; the relay cannot read requests or answers."

    private let sample: PhonePaneSample

    init(model: SettingsModel, link: PhoneLink, sample: PhonePaneSample = PhonePaneSample()) {
        self.model = model
        self.link = link
        self.sample = sample
        _justPaired = State(initialValue: sample.justPaired)
    }

    private var pairingInProgress: Bool { link.confirming != nil || link.pairingCode != nil }

    var body: some View {
        SettingsPane(tab: .phone) {
            SettingsForm {
                if let confirming = link.confirming {
                    Section("Pair an iPhone") {
                        ConfirmPairing(pairing: confirming, link: link, digits: sample.digits, mismatch: sample.mismatch) { name in justPaired = name }
                    }
                } else if let code = link.pairingCode {
                    Section("Pair an iPhone") {
                        PairingCodeView(code: code, expires: link.pairingCodeExpires) { link.cancelPairing() }
                    }
                }
                if !(pairingInProgress && link.paired.isEmpty) {
                    Section("Paired iPhones") {
                        if let justPaired {
                            Notice(.success, "Paired with \(justPaired). Requests can now go to it.")
                        }
                        if let error = link.pairingError {
                            if let plan = link.pairingPlan {
                                Notice(.error, error, action: ("See plans", { NSWorkspace.shared.open(plan.upgradeURL) }))
                            } else {
                                Notice(.error, error)
                            }
                        }
                        if link.paired.isEmpty {
                            EmptyState(symbol: "iphone", title: "No iPhone paired yet", message: Self.pairHint) {
                                pairButton
                            }
                        } else {
                            ForEach(link.paired) { pairing in
                                PairedPhoneRow(
                                    pairing: pairing, status: link.statuses[pairing.pairingId],
                                    onTest: { link.sendTest(to: pairing.pairingId) },
                                    onUnpair: { unpairing = pairing }
                                )
                            }
                            if !pairingInProgress {
                                SettingRow(hint: Self.pairHint) { pairButton }
                            }
                        }
                    }
                }
                Section("Sending") {
                    SettingRow(hint: "Someone at the Mac answers in the panel, so When I'm away sends only while nobody is.") {
                        Picker("Send requests", selection: Binding(
                            get: { model.config.phone.mode },
                            set: { value in model.update { $0.phone.push = value.rawValue } }
                        )) {
                            ForEach(Self.modes, id: \.1) { Text($0.0).tag($0.1) }
                        }
                    }
                    if model.config.phone.mode == .away {
                        SettingRow(hint: "You count as away after this long without keyboard or mouse input, or at once when the screen locks.") {
                            Picker("Away after", selection: Binding(
                                get: { model.config.phone.idleAfter },
                                set: { value in model.update { $0.phone.idleAfter = value } }
                            )) {
                                ForEach(Self.awayAfters, id: \.1) { Text($0.0).tag($0.1) }
                            }
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
                    SettingRow(hint: "While a request is open in the stew app, its clock pauses, and runs again 30 seconds after you leave it. After this long open, it times out anyway.") {
                        Picker("Longest pause while open on iPhone", selection: Binding(
                            get: { model.config.phone.viewingCap },
                            set: { value in model.update { $0.phone.viewingCap = value } }
                        )) {
                            ForEach(Self.viewingCaps, id: \.1) { Text($0.0).tag($0.1) }
                        }
                    }
                    SettingRow(hint: "Used for new pairings. A paired iPhone keeps the relay it paired with. relay-next gets new relay versions first. For another relay, such as your own, set phone.relay in config.json.") {
                        let relay = model.config.phone.relay
                        let offered = PhoneConfig.offeredRelay(relay)
                        Picker("Relay", selection: Binding(
                            get: { offered ?? relay },
                            set: { value in model.update { $0.phone.relay = value } }
                        )) {
                            ForEach(PhoneConfig.offeredRelays, id: \.self) { Text(Self.relayName($0)).tag($0) }
                            if offered == nil {
                                Text("\(relay) (set in config.json)").tag(relay)
                            }
                        }
                    }
                }
            }
        }
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

    private var pairButton: some View {
        Button("Pair an iPhone…") {
            justPaired = nil
            link.startPairing()
        }
        .buttonStyle(.borderedProminent)
    }
}

struct PairedPhoneRow: View {
    let pairing: MacPairing
    let status: RelayConnection.Status?
    /// Sends a test notification; false when it could not go.
    let onTest: () -> Bool
    let onUnpair: () -> Void
    /// Set for a few seconds after Send test, so the button says what happened.
    @State private var testSent = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 15))
                .foregroundStyle(Ink.secondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(pairing.phoneName ?? "iPhone").font(.system(size: 13, weight: .medium))
                Text("Paired \(SettingsDate.text(pairing.pairedAt ?? pairing.createdAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
                    .monospacedDigit()
            }
            Spacer()
            connection
            if let plan = neededPlan {
                Button("See plans") { NSWorkspace.shared.open(plan.upgradeURL) }
                    .help("Open \(plan.upgradeURL.absoluteString)")
            } else {
                Button(testSent ? "Sent" : "Send test") {
                    guard onTest() else { return }
                    testSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testSent = false }
                }
                .disabled(!isConnected || testSent)
                .help(isConnected ? "Send a test notification to this iPhone" : "The relay is not connected")
            }
            Button("Unpair", role: .destructive, action: onUnpair)
        }
        .padding(.vertical, 2)
    }

    private var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    private var neededPlan: RelayPlanRequired? {
        if case .stopped(.planRequired(let plan)) = status { return plan }
        return nil
    }

    @ViewBuilder
    private var connection: some View {
        switch status {
        case .connected: StatusPill(text: "Connected", tone: Tone.green.color)
        case .failed: StatusPill(text: "Relay unreachable", tone: Tone.orange.color).help("stew keeps retrying.")
        case .refused: StatusPill(text: "Relay refused this Mac", tone: Tone.orange.color).help("Check that this Mac's clock is right. stew keeps retrying.")
        case .stopped(.unsupportedProtocol): StatusPill(text: "Update stew", tone: Tone.orange.color).help("The relay needs a newer stew.")
        case .stopped(.planRequired(let plan)): StatusPill(text: "Plan needed", tone: Tone.orange.color).help("\(plan.message) stew tries again on its next start.")
        case .stopped: StatusPill(text: "Pairing gone", tone: Tone.orange.color).help("The relay no longer knows this pairing. Unpair, then pair again.")
        case .connecting, nil: StatusPill(text: "Connecting…", tone: Ink.secondary)
        }
    }
}

/// The three steps of pairing beside a square tile: the QR code while the Mac waits for
/// a phone, the phone once one has scanned it.
struct PairingLayout<Tile: View, Steps: View, Footer: View>: View {
    @ViewBuilder var tile: Tile
    @ViewBuilder var steps: Steps
    @ViewBuilder var footer: Footer

    static var tileSize: CGFloat { 196 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 22) {
                tile.frame(width: Self.tileSize, height: Self.tileSize)
                VStack(alignment: .leading, spacing: 16) { steps }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 8) { footer }
        }
        .padding(.vertical, 8)
    }
}

/// One numbered step. Done steps show a plain checkmark in place of the number.
struct PairingStep<Content: View>: View {
    enum Progress { case done, active, upcoming }

    let number: Int
    let progress: Progress
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            badge
                .frame(width: 20, height: 20)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 13, weight: progress == .active ? .semibold : .regular))
                    .foregroundStyle(progress == .upcoming ? Ink.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch progress {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Brand.paprika)
        case .active:
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Brand.paprika))
        case .upcoming:
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.secondary)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Ink.secondary.opacity(0.5)))
        }
    }
}

extension PairingStep where Content == EmptyView {
    init(number: Int, progress: Progress, title: String) {
        self.init(number: number, progress: progress, title: title, content: { EmptyView() })
    }
}

/// The QR code, and the same code as text to copy, while the Mac waits for a phone.
struct PairingCodeView: View {
    let code: PairingCode
    let expires: Date?
    let onCancel: () -> Void
    @State private var copied = false

    var body: some View {
        PairingLayout {
            if let image = Self.qrImage(code.text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
                    .accessibilityLabel("Pairing QR code")
            }
        } steps: {
            PairingStep(number: 1, progress: .active, title: "Open stew on your iPhone and tap Pair a Mac.")
            PairingStep(number: 2, progress: .active, title: "Point the camera at this code.") {
                SettingRow(hint: copied
                    ? "Copied for 1 minute. Paste it in the stew app on your iPhone."
                    : "No camera at hand? Universal Clipboard brings the code to your iPhone, where you can paste it instead of scanning.") {
                    Button("Copy code") { copy() }
                }
            }
            PairingStep(number: 3, progress: .upcoming, title: "Type the six digits your iPhone shows.")
        } footer: {
            if let expires {
                PairingCountdown(expires: expires)
            }
            Spacer()
            Button("Cancel", action: onCancel)
        }
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

/// "Code expires in 9:41", ticking each second. The digits are monospaced, so the text
/// keeps its width while it counts down.
struct PairingCountdown: View {
    let expires: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, expires.timeIntervalSince(context.date))
            let whole = Int(left.rounded(.up))
            HStack(spacing: 5) {
                Image(systemName: "timer")
                Text("Code expires in \(whole / 60):\(String(format: "%02d", whole % 60))")
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(left < 60 ? Tone.orange.color : Ink.secondary)
        }
    }
}

/// A phone has registered with the code. The user types the digits the phone shows; the
/// Mac never shows them itself, so they can only come from the phone. Until then the
/// phone's answers are ignored.
struct ConfirmPairing: View {
    let pairing: MacPairing
    @ObservedObject var link: PhoneLink
    let onPaired: (String) -> Void
    @State private var digits: String
    @State private var mismatch: Bool

    init(pairing: MacPairing, link: PhoneLink, digits: String = "", mismatch: Bool = false, onPaired: @escaping (String) -> Void) {
        self.pairing = pairing
        self.link = link
        self.onPaired = onPaired
        _digits = State(initialValue: digits)
        _mismatch = State(initialValue: mismatch)
    }

    private var phoneName: String { pairing.phoneName ?? "An iPhone" }

    var body: some View {
        PairingLayout {
            VStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Brand.paprika)
                Text(phoneName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("wants to pair")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.paprika.opacity(0.10)))
        } steps: {
            PairingStep(number: 1, progress: .done, title: "Open stew on your iPhone and tap Pair a Mac.")
            PairingStep(number: 2, progress: .done, title: "\(phoneName) scanned the code.")
            PairingStep(number: 3, progress: .active, title: "Type the six digits \(phoneName) shows.") {
                DigitsField(digits: $digits, mismatch: mismatch, onSubmit: confirm)
                    .onChange(of: digits) { mismatch = false }
                if mismatch {
                    Notice(.error, "These digits do not match. Check your iPhone again, or reject if it shows none.")
                } else {
                    Hint("If your iPhone shows no digits, reject: someone else may have used the code.")
                }
            }
        } footer: {
            Spacer()
            Button("Reject", role: .destructive) { link.unpair(pairing.pairingId) }
            Button("Confirm", action: confirm)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(digits.count != 6)
        }
    }

    private func confirm() {
        guard digits.count == 6 else { return }
        if link.confirm(pairing.pairingId, digits: digits) {
            onPaired(phoneName)
        } else {
            mismatch = true
        }
    }
}

/// Six boxes for the digits, three and three like the iPhone shows them. A plain text
/// field under the boxes takes the typing and pasting; it keeps only digits.
struct DigitsField: View {
    @Binding var digits: String
    let mismatch: Bool
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { index in
                box(index)
                if index == 2 {
                    Text("–").font(.system(size: 15)).foregroundStyle(Ink.secondary).frame(width: 10)
                }
            }
        }
        .background {
            TextField("Six digits", text: Binding(
                get: { digits },
                set: { value in digits = String(value.filter(\.isASCII).filter(\.isNumber).prefix(6)) }
            ))
            .textFieldStyle(.plain)
            .focused($focused)
            .focusEffectDisabled()
            .onSubmit(onSubmit)
            .opacity(0.02)
            .accessibilityLabel("Six digits from the iPhone")
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
    }

    private func box(_ index: Int) -> some View {
        let characters = Array(digits)
        let current = focused && index == min(characters.count, 5)
        let stroke: Color = mismatch ? Tone.orange.color : current ? Brand.paprika : Color.primary.opacity(0.18)
        return Text(index < characters.count ? String(characters[index]) : " ")
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(width: 32, height: 40)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(stroke, lineWidth: current || mismatch ? 2 : 1))
    }
}

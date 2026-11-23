import Foundation
import StewCore
import StewLink

/// `stew pair`, `stew peers` and `stew unpair`: pairing this Mac with another one through
/// the relay. The commands start a pairing and follow it; the steps that let a Mac answer
/// the other's requests happen on the panels (see `PeerRelay`).
enum PairCommands {
    /// How long `stew pair` follows a pairing: as long as its code works.
    static let waitLimit: TimeInterval = 600

    static func pair(_ arguments: Arguments) throws {
        // The code and the digits must show while the command waits, also in a pipe or
        // over ssh, where stdout is otherwise flushed only at exit.
        setlinebuf(stdout)
        if let host = arguments.options["ssh"] {
            guard arguments.positional.isEmpty else { throw UsageError("pair --ssh takes only the SSH destination") }
            try pairOverSSH(host)
            return
        }
        guard arguments.positional.count == 1 else {
            throw UsageError("pair takes `code`, a pairing code, `-` to read one from stdin, or --ssh HOST")
        }
        switch arguments.positional[0] {
        case "code": showCode(announceJoin: true)
        case "-": join(readStandardInput().trimmingCharacters(in: .whitespacesAndNewlines))
        default: join(arguments.positional[0])
        }
    }

    /// Shows a new code, then follows the pairing until both directions work.
    private static func showCode(announceJoin: Bool) {
        guard let (pairingId, code) = startCode() else { return }
        if announceJoin {
            print("""
            Pairing code (works once, for 10 minutes):

              \(code)

            On the other Mac, run:
              stew pair '\(code)'

            """)
        }
        followHost(pairingId)
    }

    private static func startCode() -> (String, String)? {
        guard control("peer code", startDaemon: true) == "started" else { fail("could not reach stew's daemon") }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let reply = control("peer code-state") ?? ""
            if reply.hasPrefix("code ") {
                let parts = reply.split(separator: " ", maxSplits: 2).map(String.init)
                if parts.count == 3 { return (parts[1], parts[2]) }
            }
            if reply.hasPrefix("error: ") { fail(String(reply.dropFirst("error: ".count))) }
            usleep(250_000)
        }
        fail("the relay did not answer in time")
    }

    private static func followHost(_ pairingId: String) {
        var said = ""
        let deadline = Date().addingTimeInterval(waitLimit)
        while Date() < deadline {
            let reply = control("peer host-state \(pairingId)") ?? "gone"
            let words = reply.split(separator: " ", maxSplits: 1).map(String.init)
            let name = words.count > 1 ? words[1] : "the other Mac"
            switch words.first {
            case "confirming" where said != "confirming":
                print("\(name) joined. Type the six digits \(name) shows on this Mac's stew panel.")
                said = "confirming"
            case "paired" where said != "paired":
                print("Paired with \(name). Waiting for \(name) to allow requests both ways…")
                said = "paired"
            case "linked":
                print("Paired with \(name) both ways: a request from either Mac shows on both.")
                return
            case "gone":
                fail("the pairing ended before it was done (canceled, declined or expired)")
            default:
                break
            }
            usleep(500_000)
        }
        fail("the pairing was not done within 10 minutes; run stew pair code again")
    }

    private static func join(_ code: String) {
        guard !code.isEmpty else { fail("no pairing code given") }
        let macName = (try? PairingCode(text: code))?.macName ?? "the other Mac"
        guard let reply = control("peer join \(code)", startDaemon: true) else { fail("could not reach stew's daemon") }
        if reply.hasPrefix("error: ") { fail(String(reply.dropFirst("error: ".count))) }
        let parts = reply.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "joined" else { fail("unexpected answer from stew's daemon: \(reply)") }
        let pairingId = parts[1]
        print("""
        Joining \(macName). To finish, on stew's panels:
          1. On \(macName), type \(parts[2]).
          2. On this Mac, allow \(macName).
        """)
        var said = ""
        let deadline = Date().addingTimeInterval(waitLimit)
        while Date() < deadline {
            let state = control("peer join-state \(pairingId)") ?? "gone"
            if state.hasPrefix("error: ") { fail(String(state.dropFirst("error: ".count))) }
            switch state {
            case "linked":
                print("Paired with \(macName) both ways: a request from either Mac shows on both.")
                return
            case "approved" where said != "approved":
                print("Allowed here. Waiting for the digits on \(macName)…")
                said = "approved"
            case "gone":
                fail("the pairing ended before it was done (declined or canceled)")
            default:
                break
            }
            usleep(500_000)
        }
        fail("the pairing was not done within 10 minutes")
    }

    /// Both halves at once: a code here, joined on HOST over SSH. SSH only carries the
    /// code; the requests always go through the relay, and both panels still confirm.
    private static func pairOverSSH(_ host: String) throws {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: \.isWhitespace) else {
            throw UsageError("\(host) is not an SSH destination")
        }
        guard let (pairingId, code) = startCode() else { return }
        print("Pairing with \(host) through the relay; ssh only carries the code.\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STEW_SSH"] ?? "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", host, remoteCommand(["pair", "-"])]
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
        } catch {
            fail("could not run ssh: \(error)")
        }
        // The code goes on stdin, so it never shows in a process list on either Mac.
        input.fileHandleForWriting.write(Data((code + "\n").utf8))
        try? input.fileHandleForWriting.close()
        followHost(pairingId)
        process.waitUntilExit()
    }

    /// stew on the other Mac. Its login shell may be fish, so the lookup runs in `sh`, in
    /// the places the installer and the Homebrew cask use: a non-interactive SSH session
    /// often has a short PATH. STEW_PEER_REMOTE_STEW replaces it, for tests.
    static func remoteCommand(_ arguments: [String]) -> String {
        let quoted = arguments.map(shellQuoted).joined(separator: " ")
        if let override = ProcessInfo.processInfo.environment["STEW_PEER_REMOTE_STEW"], !override.isEmpty {
            return "\(override) \(quoted)"
        }
        let script = #"for candidate in "$HOME/.local/bin/stew" /opt/homebrew/bin/stew /usr/local/bin/stew "$HOME/Applications/Stew.app/Contents/MacOS/stew" /Applications/Stew.app/Contents/MacOS/stew; do if [ -x "$candidate" ]; then exec "$candidate" "$@"; fi; done; if command -v stew >/dev/null 2>&1; then exec stew "$@"; fi; echo "stew is not installed on this Mac" >&2; exit 127"#
        return "sh -c \(shellQuoted(script)) stew \(quoted)"
    }

    /// Single quotes read the same in sh, bash, zsh and fish.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func list() {
        let reply = control("peer list", startDaemon: true) ?? "[]"
        let lines = (try? JSONDecoder().decode([String].self, from: Data(reply.utf8))) ?? []
        print(lines.isEmpty ? "No paired Macs. Run `stew pair code` on one Mac and `stew pair CODE` on the other." : lines.joined(separator: "\n"))
    }

    static func unpair(_ arguments: Arguments) throws {
        guard !arguments.positional.isEmpty else { throw UsageError("unpair takes the name of a paired Mac; `stew peers` lists them") }
        let name = arguments.positional.joined(separator: " ")
        let reply = control("peer unpair \(name)", startDaemon: true) ?? "could not reach stew's daemon"
        guard reply == "unpaired" else { fail(reply) }
        print("Unpaired from \(name), in both directions.")
    }

    private static func control(_ text: String, startDaemon: Bool = false) -> String? {
        Client.sendControl(text, startDaemon: startDaemon)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("stew: \(message)\n".utf8))
        exit(4)
    }
}

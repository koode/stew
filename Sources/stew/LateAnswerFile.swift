import Darwin
import Foundation
import StewCore

/// late-answers.json next to the socket, like the history. The daemon adds timed-out
/// requests and the answers given to them later; the hooks (short-lived processes)
/// deliver the answers. Mode 0600, because a waiting request is kept as it was asked.
/// The file goes when nothing is left in it, so a hook call usually finds no file.
enum LateAnswerFile {
    static var path: String { (Paths.socket as NSString).deletingLastPathComponent + "/late-answers.json" }

    static var exists: Bool { FileManager.default.fileExists(atPath: path) }

    static func read() -> LateMailbox {
        FileManager.default.contents(atPath: path).map(LateMailbox.decode) ?? LateMailbox()
    }

    /// Read, change and write under an exclusive lock, dropping what is older than a
    /// day. Writes only on change.
    @discardableResult
    static func update<Result>(now: Date = Date(), _ body: (inout LateMailbox) throws -> Result) rethrows -> Result {
        let lockFD = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer {
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }
        let original = read()
        var mailbox = original
        mailbox.prune(now: now)
        let result = try body(&mailbox)
        if mailbox != original {
            write(mailbox)
        }
        return result
    }

    /// For hooks: the answers waiting for this session and agent, marked delivered so
    /// no other hook call gets them again. Looks without the lock first, so a hook call
    /// with nothing waiting never writes.
    static func deliver(sessionID: String?, agentID: String?, event: String, now: Date = Date()) -> [LateAnswer] {
        guard exists, read().hasMail(sessionID: sessionID, agentID: agentID, now: now) else { return [] }
        let delivered = update(now: now) { mailbox in
            mailbox.deliver(sessionID: sessionID, agentID: agentID, event: event, now: now)
        }
        return delivered.map(revealSecret)
    }

    /// A late secret is not in the file: the daemon hands it over once, after the
    /// answer is marked delivered. A daemon that restarted meanwhile no longer has it,
    /// and the message then says so.
    private static func revealSecret(_ answer: LateAnswer) -> LateAnswer {
        guard answer.secretQuestion != nil else { return answer }
        let reply = Client.sendControl("late secret \(answer.entryID.uuidString)")
        let response = reply.flatMap { try? Wire.decode(StewResponse.self, line: Data($0.utf8)) }
        return answer.revealing(response?.status == .answered ? response?.text : nil)
    }

    private static func write(_ mailbox: LateMailbox) {
        guard !mailbox.isEmpty else {
            unlink(path)
            return
        }
        guard let data = try? LateMailbox.encode(mailbox) else { return }
        let temporary = path + ".tmp"
        FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600])
        if rename(temporary, path) != 0 {
            Log.append("late answers: cannot replace \(path): \(String(cString: strerror(errno)))")
        }
    }
}

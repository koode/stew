import Foundation
import StewCore

/// `stew completions install|uninstall`: writes the fish and zsh scripts where those
/// shells load them on their own, and never edits the user's dotfiles. The files it
/// wrote are listed in a record, so uninstall and updates touch exactly those, and only
/// while they still carry `CompletionScript.marker`.
enum CompletionInstaller {
    /// Next to the socket, like the update state, so a test install keeps its own list.
    static var recordPath: String { (Paths.socket as NSString).deletingLastPathComponent + "/completion-files" }

    static func install() -> Int32 {
        var written: [String] = []
        var failures = 0

        if let directory = fishDirectory() {
            let path = directory + "/" + CompletionShell.fish.fileName
            if write(.fish, to: path, &failures) {
                written.append(path)
                print("fish: wrote \(path)")
            }
        } else {
            print("fish: not found, skipped")
        }

        let probe = ZshProbe.run()
        let choice = ZshCompletionPlacement.choose(fpath: probe.fpath, home: Paths.home, isWritableDirectory: isWritableDirectory)
        let zshPath = choice.directory + "/" + CompletionShell.zsh.fileName
        if write(.zsh, to: zshPath, &failures) {
            written.append(zshPath)
            if choice.onFpath {
                print("zsh: wrote \(zshPath); new shells load it")
            } else {
                print("zsh: wrote \(zshPath). To load it, add this line to ~/.zshrc above compinit:")
                print("  fpath=(\(abbreviated(choice.directory)) $fpath)")
            }
            if probe.completionEnabled == false {
                print("zsh: completion is off in your zsh. To turn it on, add this line to ~/.zshrc:")
                print("  autoload -Uz compinit && compinit")
            }
        }

        // An earlier install may have picked another folder, for example before Homebrew.
        for path in recordedFiles() where !written.contains(path) {
            removeIfGenerated(path, &failures)
        }
        saveRecord(written)
        return failures == 0 ? 0 : 1
    }

    /// Removes the files the last install wrote. Returns the number it could not remove.
    @discardableResult
    static func uninstall() -> Int {
        var failures = 0
        for path in recordedFiles() {
            removeIfGenerated(path, &failures)
        }
        if FileManager.default.fileExists(atPath: recordPath) {
            try? FileManager.default.removeItem(atPath: recordPath)
        }
        return failures
    }

    /// Rewrites the installed scripts from this binary, so they match the version that
    /// just replaced the one that wrote them.
    static func refresh(log: (String) -> Void) {
        for path in recordedFiles() {
            let name = (path as NSString).lastPathComponent
            guard let shell = CompletionShell.allCases.first(where: { $0.fileName == name }),
                  let existing = try? String(contentsOfFile: path, encoding: .utf8),
                  CompletionScript.isGenerated(existing) else { continue }
            let script = CompletionScript.script(for: shell)
            guard existing != script else { continue }
            do {
                try script.write(toFile: path, atomically: true, encoding: .utf8)
                log("update: refreshed the \(shell.rawValue) completion in \(path)")
            } catch {
                log("update: could not refresh \(path): \(error.localizedDescription)")
            }
        }
    }

    /// fish loads `$__fish_config_dir/completions` by itself. Only when fish is installed
    /// or configured, the way the skill is only installed when ~/.claude exists.
    private static func fishDirectory() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? Paths.home + "/.config"
        let fishConfig = configHome + "/fish"
        let fileManager = FileManager.default
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fishInstalled = (pathEntries + ["/opt/homebrew/bin", "/usr/local/bin"])
            .contains { fileManager.isExecutableFile(atPath: $0 + "/fish") }
        guard fishInstalled || fileManager.fileExists(atPath: fishConfig) else { return nil }
        return fishConfig + "/completions"
    }

    private static func isWritableDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: path)
    }

    /// Writes the script unless an unrelated file of the same name is already there.
    private static func write(_ shell: CompletionShell, to path: String, _ failures: inout Int) -> Bool {
        let fileManager = FileManager.default
        if let existing = try? String(contentsOfFile: path, encoding: .utf8), !CompletionScript.isGenerated(existing) {
            print("\(shell.rawValue): left \(path) alone; it was not written by stew")
            failures += 1
            return false
        }
        do {
            try fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try CompletionScript.script(for: shell).write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("\(shell.rawValue): could not write \(path): \(error.localizedDescription)")
            failures += 1
            return false
        }
    }

    private static func removeIfGenerated(_ path: String, _ failures: inout Int) {
        guard let existing = try? String(contentsOfFile: path, encoding: .utf8), CompletionScript.isGenerated(existing) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
            print("removed \(path)")
        } catch {
            print("could not remove \(path): \(error.localizedDescription)")
            failures += 1
        }
    }

    private static func recordedFiles() -> [String] {
        guard let text = try? String(contentsOfFile: recordPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }

    private static func saveRecord(_ paths: [String]) {
        let directory = (recordPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? paths.map { $0 + "\n" }.joined().write(toFile: recordPath, atomically: true, encoding: .utf8)
    }

    private static func abbreviated(_ path: String) -> String {
        path.hasPrefix(Paths.home + "/") ? "~" + path.dropFirst(Paths.home.count) : path
    }
}

/// Reads the fpath of the user's interactive zsh, with the dotfiles it loads, because
/// that is where Homebrew's `brew shellenv` and frameworks add their folders.
enum ZshProbe {
    struct Result {
        var fpath: [String]?
        /// Whether that zsh ran compinit; nil when unknown.
        var completionEnabled: Bool?
    }

    private static let begin = "stew-fpath-begin"
    private static let end = "stew-fpath-end"

    static func run() -> Result {
        let environment = ProcessInfo.processInfo.environment
        // Tests set the fpath, so a test install never reads the real dotfiles or
        // writes into a real fpath folder.
        if let override = environment["STEW_ZSH_FPATH"] {
            return Result(fpath: override.split(separator: ":").map(String.init), completionEnabled: true)
        }
        let loginShell = environment["SHELL"] ?? ""
        let zsh = (loginShell as NSString).lastPathComponent == "zsh" && FileManager.default.isExecutableFile(atPath: loginShell) ? loginShell : "/bin/zsh"
        let script = "print -r -- \(begin); print -rl -- $fpath; print -r -- compinit=$+functions[compdef]; print -r -- \(end)"
        if let lines = output(of: zsh, ["-i", "-l", "-c", script], timeout: 10) {
            let completionLine = lines.first { $0.hasPrefix("compinit=") }
            return Result(fpath: lines.filter { $0.hasPrefix("/") }, completionEnabled: completionLine.map { $0 == "compinit=1" })
        }
        // The dotfiles failed or hung: fall back on zsh's built-in fpath.
        return Result(fpath: output(of: "/bin/zsh", ["-f", "-c", script], timeout: 5)?.filter { $0.hasPrefix("/") }, completionEnabled: nil)
    }

    /// The lines between the markers, or nil when zsh fails or runs past `timeout`.
    /// Output goes to a file rather than a pipe, so a background job started by the
    /// dotfiles cannot keep the read open.
    private static func output(of zsh: String, _ arguments: [String], timeout: TimeInterval) -> [String]? {
        let outputPath = NSTemporaryDirectory() + "stew-zsh-probe-\(getpid()).txt"
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        guard let outputHandle = FileHandle(forWritingAtPath: outputPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zsh)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        try? outputHandle.close()
        guard process.terminationStatus == 0,
              let text = try? String(contentsOfFile: outputPath, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.lastIndex(of: begin), let last = lines.lastIndex(of: end), first < last else { return nil }
        return Array(lines[(first + 1)..<last])
    }
}

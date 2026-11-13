import Foundation

/// Where Stew.app is installed and who manages it. `stew setup` and the updater act on
/// the copy that is running, wherever it is: `~/Applications` from the install script,
/// `/Applications` from the Homebrew cask, or any folder the user moved it to.
public enum InstallLocation {
    /// The token of the cask in the koode/apps tap.
    public static let caskToken = "stew"

    /// The app that updates replace: `override` (STEW_APP_PATH, for tests), else the app
    /// this binary runs from, else `~/Applications/Stew.app` for a binary outside any app
    /// (a development build).
    public static func app(override: String?, runningExecutable: String, home: String) -> String {
        if let override, !override.isEmpty { return override }
        return AppVersion.appBundle(forExecutable: runningExecutable) ?? home + "/Applications/Stew.app"
    }

    /// The tool inside an app.
    public static func executable(inApp app: String) -> String {
        app + "/Contents/MacOS/stew"
    }

    /// Homebrew prefixes to look in: HOMEBREW_PREFIX (set by `brew shellenv` and in every
    /// command brew runs, such as a cask's postflight), then the default prefixes on
    /// Apple silicon and Intel.
    public static func homebrewPrefixes(environment: [String: String]) -> [String] {
        var prefixes: [String] = []
        if let prefix = environment["HOMEBREW_PREFIX"], prefix.hasPrefix("/") {
            prefixes.append(prefix.count > 1 && prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix)
        }
        for prefix in ["/opt/homebrew", "/usr/local"] where !prefixes.contains(prefix) {
            prefixes.append(prefix)
        }
        return prefixes
    }

    /// True when the Homebrew cask installed `app`: a prefix has `Caskroom/stew` and its
    /// `bin/stew` link (the cask's `binary` stanza) leads to this app's tool. Both have
    /// to hold. The Caskroom alone also exists while an older copy in `~/Applications`
    /// runs, and the link alone could be one the user made by hand. The link is also what
    /// tells stew that Homebrew provides the command and its shell completion, so setup
    /// adds neither.
    ///
    /// `resolve` returns a path with every symbolic link followed, or nil when nothing is
    /// there.
    public static func isHomebrewCask(
        app: String,
        prefixes: [String],
        directoryExists: (String) -> Bool,
        resolve: (String) -> String?
    ) -> Bool {
        guard let tool = resolve(executable(inApp: app)) else { return false }
        return prefixes.contains { prefix in
            directoryExists(prefix + "/Caskroom/" + caskToken) && resolve(prefix + "/bin/stew") == tool
        }
    }
}

/// How an update reaches the installed app.
public enum UpdateRoute: Equatable, Sendable {
    /// Download next to the app and swap it in place.
    case inPlace
    /// This user cannot replace the app, and Homebrew installed it: `brew upgrade` can.
    case homebrew
    /// This user cannot replace the app in this folder, and no package manager owns it.
    case notWritable(folder: String)

    /// Swapping takes two renames: the app out of its folder and the new one in. That
    /// needs write access to the folder, and to the app itself, whose `..` entry changes.
    public static func choose(app: String, appWritable: Bool, folderWritable: Bool, homebrewCask: Bool) -> UpdateRoute {
        if appWritable && folderWritable { return .inPlace }
        if homebrewCask { return .homebrew }
        return .notWritable(folder: (app as NSString).deletingLastPathComponent)
    }

    /// The sentence that follows "Version X is available." when this route cannot install.
    public var note: String? {
        switch self {
        case .inPlace:
            nil
        case .homebrew:
            "stew cannot replace the app in this folder, so update it with Homebrew: brew upgrade --cask \(InstallLocation.caskToken)"
        case .notWritable(let folder):
            "stew cannot replace the app in \(folder), because this user cannot write there. Install the new version there yourself, or move Stew.app to ~/Applications."
        }
    }
}

/// The LaunchAgent that starts the daemon at login. `stew setup` writes it, for the
/// install script and the Homebrew cask alike, so either install can replace the other's.
public enum LaunchAgentPlist {
    public static func contents(label: String, executable: String, logPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    public static func data(label: String, executable: String, logPath: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: contents(label: label, executable: executable, logPath: logPath),
            format: .xml,
            options: 0
        )
    }
}

/// What `stew setup` does with the `stew` link in the bin folder (`~/.local/bin`).
public enum CommandLinkPlan: Equatable, Sendable {
    /// Already a link to this app's tool.
    case keep
    /// Make the link; nothing is there yet.
    case create
    /// A plain binary from before Stew.app, or a link to another copy of Stew.app:
    /// replace it with a link to this app's tool, so the path that hooks call keeps working.
    case replace
    /// Homebrew provides the command and nothing is there: add no link.
    case none

    /// `existing` is what is at the link path now: nil when nothing, else the resolved
    /// path it leads to (a plain file resolves to itself).
    public static func choose(existing: String?, tool: String, homebrewProvidesCommand: Bool) -> CommandLinkPlan {
        guard let existing else { return homebrewProvidesCommand ? .none : .create }
        return existing == tool ? .keep : .replace
    }
}

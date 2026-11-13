import Foundation

/// Where `stew completions install` puts `_stew`, so zsh finds it without a change to
/// the user's dotfiles. zsh loads completion functions only from the folders on its
/// `fpath`, so the choice is the first of these that works:
///
/// 1. A per-user folder that is already on fpath (`~/.zsh/completions`, `~/.zfunc`).
///    stew creates it when it is missing.
/// 2. A shared `site-functions` folder on fpath that this user can write without sudo:
///    Homebrew's (`/opt/homebrew/share/zsh/site-functions`, on fpath through
///    `brew shellenv` or Homebrew's zsh) or `/usr/local/share/zsh/site-functions` (on
///    the default fpath of macOS's own zsh, writable when Homebrew lives in /usr/local).
///    Never a folder inside a versioned install (a Homebrew Cellar), which the next
///    upgrade replaces.
/// 3. Otherwise `~/.zsh/completions`, which zsh only loads once the user adds it to
///    fpath; the installer prints that one line.
public enum ZshCompletionPlacement {
    public struct Choice: Equatable, Sendable {
        public let directory: String
        /// False when the user has to add `directory` to fpath before zsh loads it.
        public let onFpath: Bool
    }

    public static func userDirectories(home: String) -> [String] {
        [home + "/.zsh/completions", home + "/.zfunc"]
    }

    /// `fpath` is the fpath of the user's interactive zsh, or nil when it could not be read.
    public static func choose(fpath: [String]?, home: String, isWritableDirectory: (String) -> Bool) -> Choice {
        let fallback = home + "/.zsh/completions"
        let entries = (fpath ?? []).map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
        let personal = userDirectories(home: home)
        if let directory = entries.first(where: personal.contains) {
            return Choice(directory: directory, onFpath: true)
        }
        let shared = entries.first { entry in
            entry.hasSuffix("/site-functions")
                && !entry.contains("/Cellar/")
                && !entry.hasPrefix("/usr/share/")
                && isWritableDirectory(entry)
        }
        if let shared {
            return Choice(directory: shared, onFpath: true)
        }
        return Choice(directory: fallback, onFpath: false)
    }
}

import Foundation

/// Help for one subcommand, cut from the full usage text so the two can't disagree.
public enum CommandHelp {
    /// True when the arguments after the subcommand ask for its help. Help wins over
    /// everything else, so `stew permit --help` never shows a panel.
    public static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains("--help") || arguments.contains("-h")
    }

    /// The usage lines for `command` (each `stew command …` line with its indented
    /// explanation), plus the COMMON section when one of them takes `[common]`.
    /// Nil for a command the usage text does not list.
    public static func text(for command: String, usage: String) -> String? {
        let lines = usage.components(separatedBy: "\n")
        var picked: [String] = []
        var inCommand = false
        for line in lines {
            if line.hasPrefix("  stew ") {
                let name = line.dropFirst("  stew ".count).prefix { $0 != " " }
                inCommand = name == command
                if inCommand { picked.append(line) }
            } else if inCommand, line.hasPrefix("   ") {
                picked.append(line)
            } else {
                inCommand = false
            }
        }
        guard !picked.isEmpty else { return nil }
        var help = "USAGE\n" + picked.joined(separator: "\n")
        if picked.contains(where: { $0.contains("[common]") }), let common = section(named: "COMMON", in: lines) {
            help += "\n\n" + common
        }
        return help
    }

    private static func section(named title: String, in lines: [String]) -> String? {
        guard let start = lines.firstIndex(of: title) else { return nil }
        var section = [title]
        for line in lines[(start + 1)...] {
            if line.isEmpty || !line.hasPrefix(" ") { break }
            section.append(line)
        }
        return section.joined(separator: "\n")
    }
}

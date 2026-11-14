import Foundation

/// Shell command helpers: secret detection, chaining detection, word boundaries and
/// allow-rule suggestions. Kept conservative: when in doubt, mask more and match less.
public enum CommandText {
    /// Ranges of probable secrets: known token formats, secret-named assignments and
    /// flags, auth headers, URL credentials and long mixed-case random strings.
    public static func secretRanges(in command: String) -> [Range<String.Index>] {
        let text = command as NSString
        var ranges: [NSRange] = []
        for (pattern, group) in secretPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            for match in regex.matches(in: command, range: NSRange(location: 0, length: text.length)) {
                let range = match.range(at: group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                ranges.append(stripQuotes(range, in: text))
            }
        }
        return merge(ranges).compactMap { Range($0, in: command) }
    }

    /// (pattern, capture group holding the secret)
    private static let secretPatterns: [(String, Int)] = [
        (#"\bsk-ant-[A-Za-z0-9_\-]{20,}"#, 0),
        (#"\bsk-[A-Za-z0-9_\-]{20,}"#, 0),
        (#"\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}"#, 0),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, 0),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, 0),
        (#"\bglpat-[A-Za-z0-9_\-]{20,}"#, 0),
        (#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, 0),
        (#"\bnpm_[A-Za-z0-9]{30,}"#, 0),
        (#"\bAKIA[0-9A-Z]{16}\b"#, 0),
        (#"\bAIza[0-9A-Za-z_\-]{35}"#, 0),
        (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, 0),
        // FOO_TOKEN=value, DB_PASSWORD="value"
        (#"(?i)\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?)[A-Z0-9_]*=("[^"]*"|'[^']*'|[^\s;&|]+)"#, 1),
        // --password value, --token=value
        (#"(?i)(?:^|\s)--?(?:password|passwd|pass|token|secret|api-?key|access-?token|auth-?token|client-?secret)(?:=|\s+)("[^"]*"|'[^']*'|[^\s;&|]+)"#, 1),
        // Authorization: Bearer value, X-Api-Key: value
        (#"(?i)\b(?:authorization|proxy-authorization|x-api-key|api-key|x-auth-token|private-token|cookie)\s*:\s*(?:bearer\s+|basic\s+|token\s+)?([^"'\s]+)"#, 1),
        // scheme://user:password@host
        (#"://[^/\s:@]+:([^@\s/]+)@"#, 1),
        // curl -u user:password
        (#"(?:^|\s)(?:-u|--user)\s+["']?[^:\s"']+:([^\s"']+)"#, 1),
    ]

    private static let looseTokenPattern = #"[A-Za-z0-9+/_\-]{32,}={0,2}"#

    /// Shortest `/`-separated part that can make a slashed token a secret on its own.
    private static let minimumRandomSegmentLength = 16

    /// Long tokens with upper case, lower case and digits. Lowercase hex (git SHAs) and
    /// paths do not qualify. Base64 can contain `/`, so the token pattern spans slashes,
    /// but a slashed token is a path (`.claude/worktrees/agent-1a2b/Dockerfile`) unless
    /// one of its parts looks random by itself: long, with at least two upper case
    /// letters, two lower case letters and two digits. A file or folder name rarely has
    /// that (`config_Default2024`, `Stew-ab12cd34ef56`, a device UUID), a random part
    /// of a key or a webhook URL nearly always does.
    private static func randomLookingRanges(in command: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: looseTokenPattern) else { return [] }
        let text = command as NSString
        return regex.matches(in: command, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let token = text.substring(with: match.range)
            guard CharacterMix(token).hasEveryKind(atLeast: 1) else { return nil }
            guard token.contains("/") else { return match.range }
            let hasRandomSegment = token.split(separator: "/").contains { segment in
                segment.count >= minimumRandomSegmentLength && CharacterMix(segment).hasEveryKind(atLeast: 2)
            }
            return hasRandomSegment ? match.range : nil
        }
    }

    /// How many upper case letters, lower case letters and digits a token has.
    private struct CharacterMix {
        var uppercase = 0
        var lowercase = 0
        var digits = 0

        init<Text: StringProtocol>(_ token: Text) {
            for character in token {
                if character.isUppercase { uppercase += 1 } else if character.isLowercase { lowercase += 1 } else if character.isNumber { digits += 1 }
            }
        }

        func hasEveryKind(atLeast minimum: Int) -> Bool {
            uppercase >= minimum && lowercase >= minimum && digits >= minimum
        }
    }

    public static func allSecretRanges(in command: String) -> [Range<String.Index>] {
        let named = secretRanges(in: command).map { NSRange($0, in: command) }
        return merge(named + randomLookingRanges(in: command)).compactMap { Range($0, in: command) }
    }

    public static func hasSecrets(_ command: String) -> Bool {
        !allSecretRanges(in: command).isEmpty
    }

    /// For display: secrets become a fixed-width placeholder.
    public static func masked(_ command: String, placeholder: String = "••••") -> String {
        replacingSecrets(in: command, with: placeholder)
    }

    /// For allow rules: secrets become `*`, so the rule still matches without storing them.
    public static func wildcarded(_ command: String) -> String {
        replacingSecrets(in: command, with: "*")
    }

    private static func replacingSecrets(in command: String, with replacement: String) -> String {
        var result = command
        for range in allSecretRanges(in: command).reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func stripQuotes(_ range: NSRange, in text: NSString) -> NSRange {
        let value = text.substring(with: range)
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return range }
        return NSRange(location: range.location + 1, length: range.length - 2)
    }

    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// True when the command does more than run one program: chaining, pipes,
    /// redirects, background jobs, subshells or command substitution.
    public static func isCompound(_ command: String) -> Bool {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var previous: Character?
        for character in command {
            defer { previous = character }
            if escaped { escaped = false; continue }
            if character == "\\" && !inSingle { escaped = true; continue }
            if inSingle {
                if character == "'" { inSingle = false }
                continue
            }
            if character == "`" { return true }
            if character == "(" && previous == "$" { return true }
            if inDouble {
                if character == "\"" { inDouble = false }
                continue
            }
            switch character {
            case "'": inSingle = true
            case "\"": inDouble = true
            case ";", "&", "|", ">", "<", "\n", "(", ")": return true
            default: break
            }
        }
        return inSingle || inDouble
    }

    /// Word ranges, splitting on unquoted whitespace. Quotes stay part of the word.
    public static func words(_ command: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start: String.Index?
        var inSingle = false
        var inDouble = false
        var escaped = false
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            if escaped {
                escaped = false
            } else if character == "\\" && !inSingle {
                escaped = true
                if start == nil { start = index }
            } else if inSingle {
                if character == "'" { inSingle = false }
            } else if inDouble {
                if character == "\"" { inDouble = false }
            } else if character.isWhitespace {
                if let wordStart = start {
                    result.append(wordStart..<index)
                    start = nil
                }
            } else {
                if start == nil { start = index }
                if character == "'" { inSingle = true }
                if character == "\"" { inDouble = true }
            }
            index = command.index(after: index)
        }
        if let wordStart = start { result.append(wordStart..<command.endIndex) }
        return result
    }

    /// Programs whose next words are code. A prefix rule on them would allow anything.
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "fish", "python", "python3", "node", "deno", "bun", "ruby", "perl", "php",
        "eval", "exec", "sudo", "env", "xargs", "npx", "pnpx", "uvx", "osascript", "ssh", "docker", "kubectl",
    ]

    /// Candidate allow rules for a Bash command, most specific first. Secrets are `*`.
    /// A prefix always keeps the program and its subcommand, so a rule never reads
    /// `git *` for a `git push`.
    public static func ruleSuggestions(for command: String, limit: Int = 3) -> [RuleSuggestion] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCompound(trimmed) else { return [] }
        var suggestions = [RuleSuggestion(pattern: wildcarded(trimmed), kind: .exact)]
        let wordRanges = words(trimmed)
        let program = wordRanges.first.map { String(trimmed[$0]) } ?? ""
        guard !interpreters.contains(URL(fileURLWithPath: program).lastPathComponent) else { return suggestions }
        let shortest = wordRanges.count >= 3 ? 2 : 1
        if wordRanges.count > shortest {
            for length in stride(from: wordRanges.count - 1, through: shortest, by: -1) {
                let prefix = String(trimmed[trimmed.startIndex..<wordRanges[length - 1].upperBound])
                let pattern = wildcarded(prefix) + " *"
                if !suggestions.contains(where: { $0.pattern == pattern }) {
                    suggestions.append(RuleSuggestion(pattern: pattern, kind: .prefix))
                }
                if suggestions.count > limit { break }
            }
        }
        return Array(suggestions.prefix(limit))
    }

    /// Claude Code rule matching: `*` matches any text, including spaces.
    public static func matches(pattern: String, command: String) -> Bool {
        let patternCharacters = Array(pattern)
        let commandCharacters = Array(command)
        var patternIndex = 0
        var commandIndex = 0
        var starIndex = -1
        var starMatch = 0
        while commandIndex < commandCharacters.count {
            if patternIndex < patternCharacters.count, patternCharacters[patternIndex] != "*",
               patternCharacters[patternIndex] == commandCharacters[commandIndex] {
                patternIndex += 1
                commandIndex += 1
            } else if patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
                starIndex = patternIndex
                starMatch = commandIndex
                patternIndex += 1
            } else if starIndex >= 0 {
                patternIndex = starIndex + 1
                starMatch += 1
                commandIndex = starMatch
            } else {
                return false
            }
        }
        while patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
            patternIndex += 1
        }
        // "npm run *" also matches plain "npm run", as Claude Code's rules do.
        if patternIndex == patternCharacters.count { return true }
        return pattern.hasSuffix(" *") && command == String(pattern.dropLast(2))
    }
}

public struct RuleSuggestion: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case exact, prefix }
    /// Rule content as written inside `Bash(...)`. Secrets already replaced by `*`.
    public var pattern: String
    public var kind: Kind

    public init(pattern: String, kind: Kind) {
        self.pattern = pattern
        self.kind = kind
    }
}

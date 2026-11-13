import Foundation

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)

    /// macOS menu order: ⌃⌥⇧⌘.
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }

    static func parse(token: String) -> Modifiers? {
        switch token.lowercased() {
        case "ctrl", "control", "⌃": .control
        case "opt", "option", "alt", "⌥": .option
        case "shift", "⇧": .shift
        case "cmd", "command", "⌘": .command
        default: nil
        }
    }
}

public enum Key: Hashable, Sendable {
    case character(Character)
    case special(Special)

    public enum Special: String, Hashable, Sendable, CaseIterable {
        case `return`, escape, tab, space, delete, left, right, up, down
    }

    static func parse(_ token: String) -> Key? {
        let lowered = token.lowercased()
        switch lowered {
        case "return", "enter", "↩": return .special(.return)
        case "escape", "esc", "⎋": return .special(.escape)
        case "tab", "⇥": return .special(.tab)
        case "space": return .special(.space)
        case "delete", "backspace", "⌫": return .special(.delete)
        case "left", "←": return .special(.left)
        case "right", "→": return .special(.right)
        case "up", "↑": return .special(.up)
        case "down", "↓": return .special(.down)
        default:
            guard lowered.count == 1, let character = lowered.first else { return nil }
            return .character(character)
        }
    }

    public var symbol: String {
        switch self {
        case .character(let character): String(character).uppercased()
        case .special(let special):
            switch special {
            case .return: "↩"
            case .escape: "⎋"
            case .tab: "⇥"
            case .space: "Space"
            case .delete: "⌫"
            case .left: "←"
            case .right: "→"
            case .up: "↑"
            case .down: "↓"
            }
        }
    }
}

public struct Shortcut: Hashable, Sendable, CustomStringConvertible {
    public var modifiers: Modifiers
    public var key: Key

    public init(modifiers: Modifiers, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    public var description: String { modifiers.symbols + key.symbol }

    /// One piece of a shortcut as macOS menus draw it: an SF Symbol for modifiers and
    /// special keys, text for letters, digits and punctuation.
    public enum Glyph: Equatable, Sendable {
        case symbol(String)
        case text(String)
    }

    /// The pieces in menu order (⌃⌥⇧⌘, then the key). Text glyphs such as ↩ sit higher
    /// than the modifier symbols, so every special key is a symbol too.
    public var glyphs: [Glyph] {
        var glyphs: [Glyph] = []
        if modifiers.contains(.control) { glyphs.append(.symbol("control")) }
        if modifiers.contains(.option) { glyphs.append(.symbol("option")) }
        if modifiers.contains(.shift) { glyphs.append(.symbol("shift")) }
        if modifiers.contains(.command) { glyphs.append(.symbol("command")) }
        switch key {
        case .character(let character):
            glyphs.append(.text(String(character).uppercased()))
        case .special(let special):
            let name = switch special {
            case .return: "return"
            case .escape: "escape"
            case .tab: "arrow.right.to.line"
            case .space: "space"
            case .delete: "delete.left"
            case .left: "arrow.left"
            case .right: "arrow.right"
            case .up: "arrow.up"
            case .down: "arrow.down"
            }
            glyphs.append(.symbol(name))
        }
        return glyphs
    }

    /// Config text for this shortcut, such as "cmd+shift+." or "ctrl+option+return".
    public var spec: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        switch key {
        case .character(let character): parts.append(String(character))
        case .special(let special): parts.append(special.rawValue)
        }
        return parts.joined(separator: "+")
    }

    public func adding(_ extra: Modifiers) -> Shortcut {
        Shortcut(modifiers: modifiers.union(extra), key: key)
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Parses "ctrl+option" style modifier lists.
    public static func parseModifiers(_ text: String) throws -> Modifiers {
        var result: Modifiers = []
        for token in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
            guard let modifier = Modifiers.parse(token: token) else {
                throw ParseError(description: "unknown modifier \"\(token)\"")
            }
            result.insert(modifier)
        }
        return result
    }

    /// A bare key ("y") joins the chord. A full spec ("ctrl+shift+y") stands alone.
    public static func parse(_ text: String, chord: Modifiers) throws -> Shortcut {
        let tokens = text.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // "+" itself as a key arrives as two empty tokens.
        guard let keyToken = tokens.last, !keyToken.isEmpty else {
            throw ParseError(description: "missing key in \"\(text)\"")
        }
        guard let key = Key.parse(keyToken) else {
            throw ParseError(description: "unknown key \"\(keyToken)\" in \"\(text)\"")
        }
        if tokens.count == 1 {
            guard !chord.isEmpty else {
                throw ParseError(description: "\"\(text)\" has no modifier; plain keys would fire while typing")
            }
            return Shortcut(modifiers: chord, key: key)
        }
        let modifiers = try parseModifiers(tokens.dropLast().joined(separator: "+"))
        guard !modifiers.isEmpty, modifiers != .shift else {
            throw ParseError(description: "\"\(text)\" needs control, option or command; plain keys would fire while typing")
        }
        return Shortcut(modifiers: modifiers, key: key)
    }
}

public enum HotkeyAction: String, CaseIterable, Codable, Sendable {
    case approve, deny, dismiss, dismissAll, other, submit, next, previous, grant, extend
    /// A secret input: "Give me 5 min" and "I'll enter it later".
    case enterSoon, enterLater
}

/// User config at ~/.config/stew/config.json. Every field is optional.
public struct StewConfig: Codable, Equatable, Sendable {
    public var chord: String
    public var keys: [String: String]
    public var optionKeys: [String]
    /// Extra modifier needed to approve a command the check says auto mode would hard deny.
    public var hardDenyExtra: String
    /// Seconds after a panel appears during which its hotkeys do nothing, so a shortcut
    /// pressed for another app just as the panel shows cannot answer it.
    public var armDelay: Double
    /// Seconds the user has to answer a permission request or question before it
    /// answers itself with "timeout" and a note for Claude. 0 turns the limit off.
    public var responseTimeout: Double
    /// Seconds one "more time" press adds.
    public var extendBy: Double
    /// Where Claude Code's AskUserQuestion goes: "unattended" (background and remote
    /// sessions), "always" or "never". Needs the hooks.
    public var routeQuestions: String
    /// When the Stop hook turns a `needs input:` line in Claude's last message into a
    /// needs item: "unattended" (background and remote sessions), "always" or "never".
    public var autoNeeds: String
    public var sound: String?
    public var position: String
    /// A short burst of confetti where the panel was, after approving a permission request.
    public var confetti: Bool
    /// Check for a new version at start and once a day, and install it when no request is open.
    public var autoUpdate: Bool
    /// Days of request history to keep.
    public var historyDays: Int
    public var classifier: ClassifierConfig
    /// When open requests go to paired iPhones.
    public var phone: PhoneConfig

    public struct ClassifierConfig: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var model: String
        public var claudePath: String?
        public var timeoutSeconds: Double
        /// How many of the user's recent messages to show the check, for intent.
        public var recentUserMessages: Int

        public init(enabled: Bool = true, model: String = "haiku", claudePath: String? = nil, timeoutSeconds: Double = 60, recentUserMessages: Int = 6) {
            self.enabled = enabled
            self.model = model
            self.claudePath = claudePath
            self.timeoutSeconds = timeoutSeconds
            self.recentUserMessages = recentUserMessages
        }

        public init(from decoder: Decoder) throws {
            let defaults = ClassifierConfig()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
            model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
            claudePath = try container.decodeIfPresent(String.self, forKey: .claudePath)
            timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
            recentUserMessages = try container.decodeIfPresent(Int.self, forKey: .recentUserMessages) ?? defaults.recentUserMessages
        }
    }

    /// Command chord. Deny is ⌘D (the macOS "Don't Save" key) rather than ⌘⌫, which deletes
    /// a line while typing. Dismiss is ⌘. (the macOS cancel key) rather than ⌘W, which closes
    /// terminal tabs. Question paging is ⌘] / ⌘[ rather than ⌘← / ⌘→, which move the cursor.
    public static let defaultKeys: [String: String] = [
        HotkeyAction.approve.rawValue: "return",
        HotkeyAction.deny.rawValue: "d",
        HotkeyAction.dismiss.rawValue: ".",
        HotkeyAction.dismissAll.rawValue: "cmd+shift+.",
        HotkeyAction.other.rawValue: "o",
        HotkeyAction.submit.rawValue: "return",
        HotkeyAction.next.rawValue: "]",
        HotkeyAction.previous.rawValue: "[",
        HotkeyAction.grant.rawValue: "g",
        HotkeyAction.extend.rawValue: "e",
        HotkeyAction.enterSoon.rawValue: "5",
        HotkeyAction.enterLater.rawValue: "l",
    ]

    public init() {
        chord = "cmd"
        keys = Self.defaultKeys
        optionKeys = ["1", "2", "3", "4"]
        hardDenyExtra = "shift"
        armDelay = 0.5
        responseTimeout = 60
        extendBy = 120
        routeQuestions = QuestionRouting.unattended
        autoNeeds = QuestionRouting.unattended
        sound = "Glass"
        position = "top-right"
        confetti = false
        autoUpdate = true
        historyDays = History.defaultKeepDays
        classifier = ClassifierConfig()
        phone = PhoneConfig()
    }

    public init(from decoder: Decoder) throws {
        let defaults = StewConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chord = try container.decodeIfPresent(String.self, forKey: .chord) ?? defaults.chord
        let overrides = try container.decodeIfPresent([String: String].self, forKey: .keys) ?? [:]
        keys = defaults.keys.merging(overrides) { _, override in override }
        optionKeys = try container.decodeIfPresent([String].self, forKey: .optionKeys) ?? defaults.optionKeys
        hardDenyExtra = try container.decodeIfPresent(String.self, forKey: .hardDenyExtra) ?? defaults.hardDenyExtra
        armDelay = try container.decodeIfPresent(Double.self, forKey: .armDelay) ?? defaults.armDelay
        responseTimeout = try container.decodeIfPresent(Double.self, forKey: .responseTimeout) ?? defaults.responseTimeout
        extendBy = try container.decodeIfPresent(Double.self, forKey: .extendBy) ?? defaults.extendBy
        routeQuestions = try container.decodeIfPresent(String.self, forKey: .routeQuestions) ?? defaults.routeQuestions
        autoNeeds = try container.decodeIfPresent(String.self, forKey: .autoNeeds) ?? defaults.autoNeeds
        sound = try container.decodeIfPresent(String.self, forKey: .sound) ?? defaults.sound
        position = try container.decodeIfPresent(String.self, forKey: .position) ?? defaults.position
        confetti = try container.decodeIfPresent(Bool.self, forKey: .confetti) ?? defaults.confetti
        autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? defaults.autoUpdate
        historyDays = try container.decodeIfPresent(Int.self, forKey: .historyDays) ?? defaults.historyDays
        classifier = try container.decodeIfPresent(ClassifierConfig.self, forKey: .classifier) ?? defaults.classifier
        phone = try container.decodeIfPresent(PhoneConfig.self, forKey: .phone) ?? defaults.phone
    }
}

/// The parsed, conflict-checked shortcuts.
public struct Keymap: Equatable, Sendable {
    public var actions: [HotkeyAction: Shortcut]
    public var options: [Shortcut]
    public var hardDenyExtra: Modifiers

    public subscript(action: HotkeyAction) -> Shortcut { actions[action]! }

    public init(config: StewConfig) throws {
        let chord = try Shortcut.parseModifiers(config.chord)
        var actions: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases {
            let text = config.keys[action.rawValue] ?? StewConfig.defaultKeys[action.rawValue]!
            actions[action] = try Shortcut.parse(text, chord: chord)
        }
        let options = try config.optionKeys.prefix(4).map { try Shortcut.parse($0, chord: chord) }
        guard options.count == 4 else {
            throw Shortcut.ParseError(description: "optionKeys needs 4 keys, got \(options.count)")
        }
        hardDenyExtra = try Shortcut.parseModifiers(config.hardDenyExtra)

        // Two actions on one shortcut would make a panel ambiguous. Only shortcuts live on
        // the same kind of panel can collide: approve and submit may share a key.
        let optionNames = options.enumerated().map { ("option \($0.offset + 1)", $0.element) }
        func named(_ group: [HotkeyAction]) -> [(String, Shortcut)] {
            group.map { ($0.rawValue, actions[$0]!) }
        }
        let common: [HotkeyAction] = [.dismiss, .dismissAll]
        let approveExtra = ("approve past a hard deny, or always", actions[.approve]!.adding(hardDenyExtra))
        let groups = [
            named(common + [.approve, .deny, .other, .grant, .extend]) + [approveExtra],
            named(common + [.approve, .grant, .extend]) + [approveExtra] + optionNames,
            named(common + [.approve]),
            named(common + [.other, .submit, .next, .previous, .extend]) + optionNames,
            named(common + [.other, .submit, .extend, .enterSoon, .enterLater]),
        ]
        for group in groups {
            var seen: [Shortcut: String] = [:]
            for (name, shortcut) in group {
                if let earlier = seen[shortcut], earlier != name {
                    throw Shortcut.ParseError(description: "\(shortcut) is bound to both \(earlier) and \(name)")
                }
                seen[shortcut] = name
            }
        }
        self.actions = actions
        self.options = options
    }
}

extension StewConfig {
    /// Confetti follows an approved permission request, also one approved together with
    /// an "Allow more…" choice. Answers to questions and notifications get none.
    public func celebrates(_ response: StewResponse, to prompt: Prompt) -> Bool {
        guard confetti, response.status == .approved else { return false }
        if case .permission = prompt { return true }
        return false
    }
}

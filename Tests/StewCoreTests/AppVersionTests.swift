import Foundation
import Testing
@testable import StewCore

@Suite struct ShortcutGlyphTests {
    @Test func modifiersAndSpecialKeysAreSymbolsInMenuOrder() throws {
        let shortcut = try Shortcut.parse("cmd+shift+option+ctrl+return", chord: [])
        #expect(shortcut.glyphs == [.symbol("control"), .symbol("option"), .symbol("shift"), .symbol("command"), .symbol("return")])
    }

    @Test func lettersAreUppercaseTextAndPunctuationStaysText() throws {
        #expect(try Shortcut.parse("d", chord: .command).glyphs == [.symbol("command"), .text("D")])
        #expect(try Shortcut.parse(".", chord: .command).glyphs == [.symbol("command"), .text(".")])
        #expect(try Shortcut.parse("2", chord: .command).glyphs == [.symbol("command"), .text("2")])
    }

    @Test func everySpecialKeyHasASymbol() throws {
        let expected: [Key.Special: String] = [
            .return: "return", .escape: "escape", .tab: "arrow.right.to.line", .space: "space", .delete: "delete.left",
            .left: "arrow.left", .right: "arrow.right", .up: "arrow.up", .down: "arrow.down",
        ]
        for special in Key.Special.allCases {
            #expect(Shortcut(modifiers: .command, key: .special(special)).glyphs.last == .symbol(try #require(expected[special])))
        }
    }

    @Test func theStringFormStaysForTheCommandLine() throws {
        #expect(try Shortcut.parse("cmd+shift+return", chord: []).description == "⇧⌘↩")
    }
}

@Suite struct AppVersionTests {
    private func plist(_ entries: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
    }

    @Test func readsVersionAndBuildFromInfoPlist() throws {
        let data = try plist(["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "42"])
        #expect(AppVersion(infoPlist: data) == AppVersion(version: "0.2.0", build: 42))
        #expect(AppVersion(infoPlist: data)?.description == "0.2.0 (build 42)")
    }

    @Test func refusesAnIncompleteInfoPlist() throws {
        #expect(AppVersion(infoPlist: try plist(["CFBundleShortVersionString": "0.2.0"])) == nil)
        #expect(AppVersion(infoPlist: try plist(["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "abc"])) == nil)
        #expect(AppVersion(infoPlist: Data("not a plist".utf8)) == nil)
    }

    @Test func findsTheBundleAroundAnExecutable() {
        let executable = "/Users/someone/Applications/Stew.app/Contents/MacOS/stew"
        #expect(AppVersion.infoPlistPath(forExecutable: executable) == "/Users/someone/Applications/Stew.app/Contents/Info.plist")
        #expect(AppVersion.appBundle(forExecutable: executable) == "/Users/someone/Applications/Stew.app")
        #expect(AppVersion.infoPlistPath(forExecutable: "/repo/.build/debug/stew") == nil)
        #expect(AppVersion.infoPlistPath(forExecutable: "/tmp/Contents/MacOS/stew") == nil)
    }

    @Test func describesADevelopmentBuild() {
        #expect(AppVersion(version: "0.1.0", build: nil).description == "0.1.0 (development build, not in an app bundle)")
    }
}

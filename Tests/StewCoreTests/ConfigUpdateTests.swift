import Foundation
import Testing
@testable import StewCore

@Suite struct ConfigUpdateTests {
    @Test func aChangeKeepsWhatAnotherWindowWroteMeanwhile() throws {
        // Settings loaded the file before the setup window marked setup as done.
        let loadedBySettings = StewConfig()
        let onDisk = Data(#"{"setup":{"completed":true},"sound":""}"#.utf8)
        let result = try StewConfig.updatingFile(onDisk, loaded: loadedBySettings) { $0.confetti = true }
        #expect(result.config.setup.completed)
        #expect(result.config.sound == "")
        #expect(result.config.confetti)
        let written = try JSONDecoder().decode(StewConfig.self, from: result.data)
        #expect(written.setup.completed)
        #expect(written.confetti)
    }

    @Test func aMissingOrBrokenFileStartsFromTheLoadedCopy() throws {
        var loaded = StewConfig()
        loaded.responseTimeout = 120
        let missing = try StewConfig.updatingFile(nil, loaded: loaded) { $0.menuBar = false }
        #expect(missing.config.responseTimeout == 120)
        #expect(!missing.config.menuBar)
        let broken = try StewConfig.updatingFile(Data("{".utf8), loaded: loaded) { $0.menuBar = false }
        #expect(broken.config.responseTimeout == 120)
    }

    @Test func clashingKeysAreRefused() {
        #expect(throws: (any Error).self) {
            try StewConfig.updatingFile(nil, loaded: StewConfig()) { $0.keys["deny"] = "return" }
        }
    }
}

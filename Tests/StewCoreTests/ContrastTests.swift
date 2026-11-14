import Foundation
import Testing
@testable import StewCore

struct ContrastTests {
    @Test func theRatioMatchesWCAG() {
        #expect(abs(RGB.contrast(.black, .white) - 21) < 0.01)
        #expect(abs(RGB.contrast(RGB(hex: 0x777777), .white) - 4.48) < 0.01)
    }

    private let lightSurfaces = Surface.all(dark: false)
    private let darkSurfaces = Surface.all(dark: true)

    @Test func everyToneReadsOnItsCapsuleInBothAppearances() {
        for tone in Tone.allCases {
            for (text, surfaces) in [(tone.light, lightSurfaces), (tone.dark, darkSurfaces)] {
                for surface in surfaces {
                    let capsule = text.over(surface, alpha: Tone.fillAlpha)
                    let ratio = RGB.contrast(text, capsule)
                    #expect(ratio >= 4.5, Comment(rawValue: "\(tone) on \(capsule): \(ratio)"))
                }
            }
        }
    }

    @Test func secondaryTextReadsOnEverySurface() {
        for surface in lightSurfaces {
            let text = RGB.black.over(surface, alpha: Ink.secondaryLightAlpha)
            #expect(RGB.contrast(text, surface) >= 4.5)
            // A neutral capsule: the secondary color itself at the fill opacity.
            #expect(RGB.contrast(text, text.over(surface, alpha: Tone.fillAlpha)) >= 4.5)
        }
        for surface in darkSurfaces {
            let text = RGB.white.over(surface, alpha: Ink.secondaryDarkAlpha)
            #expect(RGB.contrast(text, surface) >= 4.5)
            #expect(RGB.contrast(text, text.over(surface, alpha: Tone.fillAlpha)) >= 4.5)
        }
    }

    /// The system colors stew used before: most are below 4.5 on their own capsule.
    @Test func theSystemBlueFailedOnWhite() {
        let systemBlue = RGB(hex: 0x0088FF)
        #expect(RGB.contrast(systemBlue, systemBlue.over(.white, alpha: Tone.fillAlpha)) < 4.5)
    }
}

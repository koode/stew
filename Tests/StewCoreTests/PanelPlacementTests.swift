import CoreGraphics
import Foundation
import Testing
@testable import StewCore

struct PanelPlacementTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 480, height: 200)

    @Test func cornersSitAtTheTopOfTheScreen() {
        #expect(PanelPlacement.corner("top-right", size: size, visible: visible) == CGRect(x: 946, y: 661, width: 480, height: 200))
        #expect(PanelPlacement.corner("top-left", size: size, visible: visible) == CGRect(x: 14, y: 661, width: 480, height: 200))
        #expect(PanelPlacement.corner("top-center", size: size, visible: visible) == CGRect(x: 480, y: 661, width: 480, height: 200))
    }

    @Test func aCornerOnASecondScreenUsesThatScreen() {
        let left = CGRect(x: -1920, y: 200, width: 1920, height: 1055)
        #expect(PanelPlacement.corner("top-right", size: size, visible: left) == CGRect(x: -494, y: 1041, width: 480, height: 200))
    }

    @Test func aFrameOnScreenStaysWhereItIs() {
        let frame = CGRect(x: 300, y: 300, width: 480, height: 200)
        #expect(PanelPlacement.clamp(frame, into: visible) == frame)
    }

    @Test func aFramePastTheTopComesDown() {
        // The screen under it got shorter: the header was above the visible area.
        let frame = CGRect(x: 946, y: 800, width: 480, height: 200)
        #expect(PanelPlacement.clamp(frame, into: visible) == CGRect(x: 946, y: 675, width: 480, height: 200))
    }

    @Test func aFramePastTheSidesAndBottomComesBack() {
        #expect(PanelPlacement.clamp(CGRect(x: 1200, y: -50, width: 480, height: 200), into: visible) == CGRect(x: 960, y: 0, width: 480, height: 200))
        #expect(PanelPlacement.clamp(CGRect(x: -100, y: 100, width: 480, height: 200), into: visible) == CGRect(x: 0, y: 100, width: 480, height: 200))
    }

    @Test func aFrameLargerThanTheScreenKeepsItsTopLeftOnScreen() {
        let frame = CGRect(x: 500, y: 500, width: 1600, height: 1000)
        #expect(PanelPlacement.clamp(frame, into: visible) == CGRect(x: 0, y: -125, width: 1600, height: 1000))
    }

    @Test func bottomSpotsSitAtTheBottomOfTheScreen() {
        #expect(PanelPlacement.corner("bottom-right", size: size, visible: visible) == CGRect(x: 946, y: 14, width: 480, height: 200))
        #expect(PanelPlacement.corner("bottom-center", size: size, visible: visible) == CGRect(x: 480, y: 14, width: 480, height: 200))
        #expect(PanelPlacement.corner("bottom-left", size: size, visible: visible) == CGRect(x: 14, y: 14, width: 480, height: 200))
    }

    @Test func anUnknownPositionIsTopRight() {
        #expect(PanelPlacement.corner("middle", size: size, visible: visible) == PanelPlacement.corner("top-right", size: size, visible: visible))
    }

    @Test func aDragSnapsToTheThirdAndHalfItWasLetGoIn() {
        func letGo(atX x: CGFloat, y: CGFloat) -> String {
            PanelPlacement.nearest(to: CGRect(x: x - 240, y: y - 100, width: 480, height: 200), in: visible)
        }
        #expect(letGo(atX: 100, y: 800) == "top-left")
        #expect(letGo(atX: 720, y: 800) == "top-center")
        #expect(letGo(atX: 1400, y: 500) == "top-right")
        #expect(letGo(atX: 100, y: 100) == "bottom-left")
        #expect(letGo(atX: 720, y: 400) == "bottom-center")
        #expect(letGo(atX: 1400, y: 100) == "bottom-right")
    }

    @Test func aDragOnAnotherDisplaySnapsWithinThatDisplay() {
        let right = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
        #expect(PanelPlacement.nearest(to: CGRect(x: 1500, y: 1100, width: 480, height: 200), in: right) == "top-left")
    }

    @Test func resizingKeepsTheAnchoredEdges() {
        let frame = CGRect(x: 500, y: 300, width: 480, height: 200)
        let taller = CGSize(width: 480, height: 300)
        #expect(PanelPlacement.resized(frame, to: taller, position: "top-right") == CGRect(x: 500, y: 200, width: 480, height: 300))
        #expect(PanelPlacement.resized(frame, to: taller, position: "bottom-right") == CGRect(x: 500, y: 300, width: 480, height: 300))
        let wider = CGSize(width: 600, height: 200)
        #expect(PanelPlacement.resized(frame, to: wider, position: "top-right").minX == 380)
        #expect(PanelPlacement.resized(frame, to: wider, position: "top-left").minX == 500)
        #expect(PanelPlacement.resized(frame, to: wider, position: "bottom-center").minX == 440)
    }

    @Test func everyPositionPlacesThePanelInsideTheScreen() {
        for position in PanelPlacement.positions {
            let frame = PanelPlacement.corner(position, size: size, visible: visible)
            #expect(PanelPlacement.clamp(frame, into: visible) == frame)
            #expect(PanelPlacement.nearest(to: frame, in: visible) == position)
        }
    }

    @Test func theConfigKeepsTheDisplayAndLeavesItOutWhenUnset() throws {
        let decoded = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"position":"bottom-left","display":"37D8832A-2D66-02CA-B9F7-8F30A301B230"}"#.utf8))
        #expect(decoded.position == "bottom-left")
        #expect(decoded.display == "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        let unset = String(decoding: try JSONEncoder().encode(StewConfig()), as: UTF8.self)
        #expect(!unset.contains("display"))
    }
}

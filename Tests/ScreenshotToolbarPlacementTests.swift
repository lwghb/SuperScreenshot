import CoreGraphics
import Testing
@testable import SuperScreenshot

struct ScreenshotToolbarPlacementTests {
    @Test func finishAlignsWithWideSelectionRightEdge() {
        let selection = CGRect(x: 200, y: 200, width: 900, height: 400)
        let frame = ScreenshotToolbarPlacement.frame(selection: selection, size: CGSize(width: 348, height: 48), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(frame.maxX - 8 == selection.maxX)
        #expect(frame.maxY == selection.minY - 8)
    }

    @Test func narrowSelectionStillKeepsConfirmationNearItsRightCorner() {
        let selection = CGRect(x: 600, y: 200, width: 40, height: 200)
        let frame = ScreenshotToolbarPlacement.frame(selection: selection, size: CGSize(width: 442, height: 48), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(frame.maxX - 8 == selection.maxX)
    }

    @Test func screenEdgesClampAndBottomSelectionMovesToolbarAbove() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for selection in [CGRect(x: 0, y: 0, width: 40, height: 100), CGRect(x: 1300, y: 200, width: 140, height: 200)] {
            let frame = ScreenshotToolbarPlacement.frame(selection: selection, size: CGSize(width: 348, height: 48), visibleFrame: screen)
            #expect(screen.insetBy(dx: 12, dy: 12).contains(frame))
            if selection.minY == 0 { #expect(frame.minY == selection.maxY + 8) }
        }
    }

    @Test func negativeCoordinateDisplayUsesTheSameAlignment() {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let selection = CGRect(x: -1000, y: 400, width: 600, height: 300)
        let frame = ScreenshotToolbarPlacement.frame(selection: selection, size: CGSize(width: 348, height: 48), visibleFrame: screen)
        #expect(frame.maxX - 8 == selection.maxX)
        #expect(screen.insetBy(dx: 12, dy: 12).contains(frame))
    }
}

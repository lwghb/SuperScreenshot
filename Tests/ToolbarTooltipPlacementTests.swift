import CoreGraphics
import Testing
@testable import SuperScreenshot

struct ToolbarTooltipPlacementTests {
    @Test func staysAboveHoveredButtonAndCursor() {
        let target = CGRect(x: 300, y: 200, width: 34, height: 32)
        let pointer = CGPoint(x: 315, y: 215)
        let frame = ToolbarTooltipPlacement.frame(target: target, size: CGSize(width: 120, height: 26), pointer: pointer, visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(frame.minY >= target.maxY + 12)
        #expect(!frame.contains(pointer))
    }

    @Test func avoidsCursorWhenButtonTouchesTopEdge() {
        let target = CGRect(x: 300, y: 560, width: 34, height: 32)
        let pointer = CGPoint(x: 315, y: 561)
        let frame = ToolbarTooltipPlacement.frame(target: target, size: CGSize(width: 150, height: 26), pointer: pointer, visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(frame.maxY < pointer.y - 32)
        #expect(frame.maxY < target.minY)
    }

    @Test func staysVisibleOnOffsetDisplayAtEveryEdge() {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        for origin in [CGPoint(x: -1440, y: 100), CGPoint(x: -34, y: 100), CGPoint(x: -1440, y: 968), CGPoint(x: -34, y: 968)] {
            let target = CGRect(origin: origin, size: CGSize(width: 34, height: 32))
            let pointer = CGPoint(x: target.midX, y: target.midY)
            let frame = ToolbarTooltipPlacement.frame(target: target, size: CGSize(width: 280, height: 30), pointer: pointer, visibleFrame: screen)
            #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
            #expect(!frame.intersects(CGRect(x: pointer.x - 6, y: pointer.y - 32, width: 34, height: 40)))
        }
    }
}

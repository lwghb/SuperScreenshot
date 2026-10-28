import CoreGraphics

enum ScreenshotToolbarPlacement {
    static func frame(selection: CGRect, size: CGSize, visibleFrame: CGRect, finishTrailingInset: CGFloat = 8) -> CGRect {
        let visible = visibleFrame.insetBy(dx: 12, dy: 12)
        // Keep the confirmation control beside the selection's right edge,
        // rather than centring the whole strip beneath a wide screenshot.
        let desiredX = selection.maxX - size.width + finishTrailingInset
        let x = min(max(desiredX, visible.minX), max(visible.minX, visible.maxX - size.width))
        var y = selection.minY - size.height - 8
        if y < visible.minY { y = selection.maxY + 8 }
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

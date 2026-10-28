import CoreGraphics

/// Positions labels outside both the hovered control and the cursor footprint.
enum ToolbarTooltipPlacement {
    static func frame(target: CGRect, size: CGSize, pointer: CGPoint, visibleFrame: CGRect) -> CGRect {
        let limits = visibleFrame.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(size.width, limits.width), height: min(size.height, limits.height))
        let cursor = CGRect(x: pointer.x - 6, y: pointer.y - 32, width: 34, height: 40)
        func clampedX(_ x: CGFloat) -> CGFloat { min(max(x, limits.minX), limits.maxX - size.width) }
        let centeredX = clampedX(target.midX - size.width / 2)
        let candidates = [
            CGRect(origin: CGPoint(x: centeredX, y: target.maxY + 12), size: size),
            CGRect(origin: CGPoint(x: centeredX, y: target.minY - size.height - 36), size: size),
            CGRect(origin: CGPoint(x: target.maxX + 36, y: target.midY - size.height / 2), size: size),
            CGRect(origin: CGPoint(x: target.minX - size.width - 12, y: target.midY - size.height / 2), size: size),
            CGRect(origin: CGPoint(x: clampedX(pointer.x - size.width / 2), y: pointer.y + 12), size: size),
            CGRect(origin: CGPoint(x: clampedX(pointer.x - size.width / 2), y: pointer.y - size.height - 36), size: size)
        ]
        if let frame = candidates.first(where: { limits.contains($0) && !$0.intersects(cursor) }) { return frame }
        let corners = [
            CGPoint(x: limits.minX, y: limits.maxY - size.height),
            CGPoint(x: limits.maxX - size.width, y: limits.maxY - size.height),
            CGPoint(x: limits.minX, y: limits.minY),
            CGPoint(x: limits.maxX - size.width, y: limits.minY)
        ].map { CGRect(origin: $0, size: size) }
        return corners.max { a, b in
            hypot(a.midX - pointer.x, a.midY - pointer.y) < hypot(b.midX - pointer.x, b.midY - pointer.y)
        } ?? CGRect(origin: limits.origin, size: size)
    }
}

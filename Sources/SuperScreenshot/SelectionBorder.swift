import AppKit

@MainActor
final class SelectionBorderController {
    private var selection: CGRect
    private let editable: Bool
    private let allowedFrame: CGRect?
    private let onSelectionChanged: ((CGRect) -> Void)?
    private var window: NSPanel?

    init(
        selection: CGRect,
        editable: Bool = false,
        allowedFrame: CGRect? = nil,
        onSelectionChanged: ((CGRect) -> Void)? = nil
    ) {
        self.selection = selection
        self.editable = editable
        self.allowedFrame = allowedFrame
        self.onSelectionChanged = onSelectionChanged
    }

    func show() {
        let thickness: CGFloat = 4
        let glowInset: CGFloat = 8
        let frame = selection.insetBy(dx: -(thickness / 2 + glowInset), dy: -(thickness / 2 + glowInset))
        let panel = NSPanel(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = !editable
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = SelectionBorderView(
            frame: CGRect(origin: .zero, size: frame.size),
            thickness: thickness,
            inset: thickness / 2 + glowInset,
            editable: editable,
            selection: selection,
            onResize: { [weak self] selection in
                self?.updateSelection(selection)
            }
        )
        window = panel
        panel.orderFrontRegardless()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    func lockEditing() {
        window?.ignoresMouseEvents = true
    }

    private func updateSelection(_ proposedSelection: CGRect) {
        var updated = proposedSelection.standardized
        if let allowedFrame {
            updated.origin.x = max(allowedFrame.minX, min(updated.origin.x, allowedFrame.maxX - updated.width))
            updated.origin.y = max(allowedFrame.minY, min(updated.origin.y, allowedFrame.maxY - updated.height))
            updated.size.width = min(updated.width, allowedFrame.maxX - updated.minX)
            updated.size.height = min(updated.height, allowedFrame.maxY - updated.minY)
        }
        guard updated.width >= 2, updated.height >= 2 else { return }
        selection = updated
        (window?.contentView as? SelectionBorderView)?.setSelection(updated)
        let thickness: CGFloat = 4
        let glowInset: CGFloat = 8
        let frame = updated.insetBy(dx: -(thickness / 2 + glowInset), dy: -(thickness / 2 + glowInset))
        window?.setFrame(frame, display: true)
        onSelectionChanged?(updated)
    }
}

private final class SelectionBorderView: NSView {
    private let thickness: CGFloat
    private let inset: CGFloat
    private let editable: Bool
    private var selection: CGRect
    private let onResize: ((CGRect) -> Void)?
    private enum ResizeEdge: Hashable { case left, right, top, bottom }
    private var activeEdges = Set<ResizeEdge>()
    private var dragStartPoint: CGPoint?
    private var dragStartSelection: CGRect?
    private var trackingAreaRef: NSTrackingArea?

    init(
        frame: CGRect,
        thickness: CGFloat,
        inset: CGFloat,
        editable: Bool = false,
        selection: CGRect = .zero,
        onResize: ((CGRect) -> Void)? = nil
    ) {
        self.thickness = thickness
        self.inset = inset
        self.editable = editable
        self.selection = selection
        self.onResize = onResize
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Long capture and screen recording are active operations.  A red
        // outline makes that state distinct from the blue screenshot editor.
        let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
        let glow = NSShadow()
        glow.shadowColor = NSColor.systemRed.withAlphaComponent(0.9)
        glow.shadowBlurRadius = 9
        glow.shadowOffset = .zero
        glow.set()
        NSColor.systemRed.setStroke()
        path.lineWidth = thickness
        path.stroke()

        // Match the screenshot editor's resize affordance: a small white
        // circular knob with a colored outline at every corner.
        guard editable else { return }
        let rect = bounds.insetBy(dx: inset, dy: inset)
        for point in [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ] {
            let knob = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knob).fill()
            NSColor.systemRed.setStroke()
            let outline = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    func setSelection(_ selection: CGRect) {
        self.selection = selection
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        guard editable else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(for: event) }

    private func updateCursor(for event: NSEvent) {
        guard editable, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let tolerance: CGFloat = 20
        let nearLeft = abs(point.x - selection.minX) <= tolerance
        let nearRight = abs(point.x - selection.maxX) <= tolerance
        let nearBottom = abs(point.y - selection.minY) <= tolerance
        let nearTop = abs(point.y - selection.maxY) <= tolerance
        if (nearLeft || nearRight) && (nearBottom || nearTop) {
            if (nearLeft && nearBottom) || (nearRight && nearTop) {
                RecordingResizeCursor.diagonalRising.set()
            } else {
                RecordingResizeCursor.diagonalFalling.set()
            }
        } else if nearLeft || nearRight {
            NSCursor.resizeLeftRight.set()
        } else if nearBottom || nearTop {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard editable, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let tolerance: CGFloat = 20
        var edges = Set<ResizeEdge>()
        if abs(point.x - selection.minX) <= tolerance { edges.insert(.left) }
        if abs(point.x - selection.maxX) <= tolerance { edges.insert(.right) }
        if abs(point.y - selection.minY) <= tolerance { edges.insert(.bottom) }
        if abs(point.y - selection.maxY) <= tolerance { edges.insert(.top) }
        guard !edges.isEmpty else { return }
        activeEdges = edges
        dragStartPoint = point
        dragStartSelection = selection
    }

    override func mouseDragged(with event: NSEvent) {
        guard editable,
              let window,
              let startPoint = dragStartPoint,
              let startSelection = dragStartSelection,
              !activeEdges.isEmpty else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
        var updated = startSelection
        let minimum: CGFloat = 24
        if activeEdges.contains(.left) {
            let maxX = startSelection.maxX - minimum
            updated.origin.x = min(startSelection.minX + delta.x, maxX)
            updated.size.width = startSelection.maxX - updated.minX
        }
        if activeEdges.contains(.right) {
            updated.size.width = max(minimum, startSelection.width + delta.x)
        }
        if activeEdges.contains(.bottom) {
            let maxY = startSelection.maxY - minimum
            updated.origin.y = min(startSelection.minY + delta.y, maxY)
            updated.size.height = startSelection.maxY - updated.minY
        }
        if activeEdges.contains(.top) {
            updated.size.height = max(minimum, startSelection.height + delta.y)
        }
        onResize?(updated)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges.removeAll()
        dragStartPoint = nil
        dragStartSelection = nil
    }
}

@MainActor
private enum RecordingResizeCursor {
    static let diagonalRising = makeCursor(rising: true)
    static let diagonalFalling = makeCursor(rising: false)

    private static func makeCursor(rising: Bool) -> NSCursor {
        let image = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { _ in
            let start = rising ? CGPoint(x: 3, y: 3) : CGPoint(x: 3, y: 17)
            let end = rising ? CGPoint(x: 17, y: 17) : CGPoint(x: 17, y: 3)
            let direction = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let length = hypot(direction.x, direction.y)
            let unit = CGPoint(x: direction.x / length, y: direction.y / length)
            let perpendicular = CGPoint(x: -unit.y, y: unit.x)
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            for (tip, sign) in [(start, CGFloat(1)), (end, CGFloat(-1))] {
                let base = CGPoint(x: tip.x + unit.x * 5 * sign, y: tip.y + unit.y * 5 * sign)
                path.move(to: tip)
                path.line(to: CGPoint(x: base.x + perpendicular.x * 3, y: base.y + perpendicular.y * 3))
                path.move(to: tip)
                path.line(to: CGPoint(x: base.x - perpendicular.x * 3, y: base.y - perpendicular.y * 3))
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 4
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 2
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 10, y: 10))
    }
}

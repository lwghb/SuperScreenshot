import AppKit

@MainActor
final class SelectionBorderController {
    private let selection: CGRect
    private var window: NSPanel?

    init(selection: CGRect) {
        self.selection = selection
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
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = SelectionBorderView(
            frame: CGRect(origin: .zero, size: frame.size),
            thickness: thickness,
            inset: thickness / 2 + glowInset
        )
        window = panel
        panel.orderFrontRegardless()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class SelectionBorderView: NSView {
    private let thickness: CGFloat
    private let inset: CGFloat

    init(frame: CGRect, thickness: CGFloat, inset: CGFloat) {
        self.thickness = thickness
        self.inset = inset
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
    }
}

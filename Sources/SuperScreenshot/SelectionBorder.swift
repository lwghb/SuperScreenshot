import AppKit

@MainActor
final class SelectionBorderController {
    private let selection: CGRect
    private var window: NSPanel?

    init(selection: CGRect) {
        self.selection = selection
    }

    func show() {
        let thickness: CGFloat = 3
        let frame = selection.insetBy(dx: -thickness / 2, dy: -thickness / 2)
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
        panel.contentView = SelectionBorderView(frame: CGRect(origin: .zero, size: frame.size), thickness: thickness)
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

    init(frame: CGRect, thickness: CGFloat) {
        self.thickness = thickness
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: thickness / 2, dy: thickness / 2))
        path.lineWidth = thickness
        path.stroke()
    }
}

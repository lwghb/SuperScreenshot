import AppKit

@MainActor
final class SelectionBorderController {
    private let selection: CGRect
    private var windows: [NSPanel] = []

    init(selection: CGRect) {
        self.selection = selection
    }

    func show() {
        let thickness: CGFloat = 3
        let gap: CGFloat = 2
        let pieces = [
            CGRect(x: selection.minX, y: selection.maxY + gap, width: selection.width, height: thickness),
            CGRect(x: selection.minX, y: selection.minY - thickness - gap, width: selection.width, height: thickness),
            CGRect(x: selection.minX - thickness - gap, y: selection.minY, width: thickness, height: selection.height),
            CGRect(x: selection.maxX + gap, y: selection.minY, width: thickness, height: selection.height)
        ]

        windows = pieces.map { frame in
            let panel = NSPanel(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.sharingType = .none
            panel.backgroundColor = .systemBlue
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return panel
        }
        windows.forEach { $0.orderFrontRegardless() }
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

import AppKit

@MainActor
final class ActionBarController: NSObject {
    var onEdit: (() -> Void)?
    var onLongCapture: (() -> Void)?
    var onCopy: (() -> Void)?
    private let selection: CGRect
    private let screen: NSScreen
    private var window: NSPanel?

    init(selection: CGRect, screen: NSScreen) {
        self.selection = selection
        self.screen = screen
    }

    func show() {
        let size = CGSize(width: 280, height: 52)
        var x = selection.midX - size.width / 2
        var y = selection.minY - size.height - 8
        x = min(max(x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
        if y < screen.visibleFrame.minY { y = selection.maxY + 8 }

        let panel = NSPanel(
            contentRect: CGRect(origin: CGPoint(x: x, y: y), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97)
        panel.isOpaque = false
        panel.hasShadow = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(button("编辑", action: #selector(edit)))
        stack.addArrangedSubview(button("长截图", action: #selector(longShot)))
        stack.addArrangedSubview(button("完成", action: #selector(copyImage)))
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        window = panel
        panel.orderFrontRegardless()
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    @objc private func edit() { onEdit?() }
    @objc private func longShot() { onLongCapture?() }
    @objc private func copyImage() { onCopy?() }
    func close() { window?.orderOut(nil); window = nil }
}

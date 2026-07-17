import AppKit

@MainActor
final class LongCaptureStatusController: NSObject {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAutoScrollToggle: (() -> Void)?
    private let selection: CGRect
    private let screen: NSScreen
    private var window: NSPanel?
    private let imageView = NSImageView()
    private let escapeHotKey = GlobalHotKeyManager(identifier: 2)
    private lazy var autoScrollButton = button(L("自动滚动"), action: #selector(toggleAutoScroll))

    init(selection: CGRect, screen: NSScreen) {
        self.selection = selection
        self.screen = screen
    }

    func show() {
        let width: CGFloat = 300
        let height = min(CGFloat(600), screen.visibleFrame.height - 40)
        let size = CGSize(width: width, height: height)
        let rightX = selection.maxX + 12
        let leftX = selection.minX - width - 12
        let x: CGFloat
        if rightX + width <= screen.visibleFrame.maxX {
            x = rightX
        } else if leftX >= screen.visibleFrame.minX {
            x = leftX
        } else {
            x = screen.visibleFrame.maxX - width - 12
        }
        let y = min(max(selection.midY - height / 2, screen.visibleFrame.minY + 12), screen.visibleFrame.maxY - height - 12)

        let panel = NSPanel(
            contentRect: CGRect(origin: CGPoint(x: x, y: y), size: size),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L("长截图实时预览")
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignTop
        imageView.imageFrameStyle = .grayBezel
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let finishButton = button(L("完成"), action: #selector(finish))
        finishButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [autoScrollButton, finishButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(imageView)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            imageView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        panel.contentView = content
        window = panel
        panel.orderFrontRegardless()

        escapeHotKey.onPressed = { [weak self] in self?.onCancel?() }
        escapeHotKey.register(keyCode: 53, modifiersRaw: 0)
    }

    func update(preview: CGImage) {
        imageView.image = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
    }

    func setAutoScrolling(_ isScrolling: Bool) {
        autoScrollButton.title = isScrolling ? L("停止滚动") : L("自动滚动")
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func finish() { onFinish?() }
    @objc private func toggleAutoScroll() { onAutoScrollToggle?() }
    func close() {
        escapeHotKey.invalidate()
        window?.orderOut(nil)
        window = nil
    }
}

import AppKit

@MainActor
final class RecordingToolbarController: NSObject {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onBack: (() -> Void)?
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt: Date?
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let startButton = NSButton(title: L("开始录屏"), target: nil, action: nil)
    private weak var backButton: NSButton?
    private weak var contentView: NSView?

    func show(in screen: NSScreen, below selection: CGRect) {
        let size = CGSize(width: 360, height: 64)
        var x = selection.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        var y = selection.minY - size.height - 12
        if y < screen.visibleFrame.minY + 8 { y = selection.maxY + 12 }
        let frame = CGRect(x: x,
                           y: y,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        content.material = .hudWindow
        content.blendingMode = .withinWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        let back = NSButton(title: "", target: self, action: #selector(back))
        back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: L("返回截图"))
        back.imagePosition = .imageOnly
        back.toolTip = L("返回截图")
        back.frame = CGRect(x: 16, y: 14, width: 36, height: 36)
        backButton = back
        startButton.target = self; startButton.action = #selector(toggle)
        startButton.bezelStyle = .rounded
        startButton.frame = CGRect(x: (size.width - 112) / 2, y: 14, width: 112, height: 36)
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timerLabel.isHidden = true
        timerLabel.alignment = .right
        timerLabel.frame = CGRect(x: 78, y: 21, width: 78, height: 22)
        content.addSubview(back); content.addSubview(timerLabel); content.addSubview(startButton)
        panel.contentView = content
        contentView = content
        self.panel = panel
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        panel.setFrame(frame.offsetBy(dx: 0, dy: -10), display: false)
        panel.orderFrontRegardless()
        if panel.alphaValue == 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    @objc private func toggle() {
        if startedAt == nil {
            startedAt = Date(); startButton.title = L("结束录屏")
            startButton.isBordered = true
            startButton.bezelStyle = .texturedRounded
            startButton.wantsLayer = true
            startButton.layer?.backgroundColor = NSColor.systemRed.cgColor
            startButton.layer?.cornerRadius = 7
            startButton.layer?.masksToBounds = true
            startButton.contentTintColor = .white
            startButton.attributedTitle = NSAttributedString(string: L("结束录屏"), attributes: [.foregroundColor: NSColor.white])
            timerLabel.isHidden = false; backButton?.isHidden = true
            startButton.frame.origin.x = 176
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateTimer() }
            onStart?()
        } else { onStop?() }
    }
    private func updateTimer() { guard let startedAt else { return }; timerLabel.stringValue = String(format: "%02d:%02d", Int(Date().timeIntervalSince(startedAt)) / 60, Int(Date().timeIntervalSince(startedAt)) % 60) }
    @objc private func back() { onBack?() }
    func recordingDidStop() {
        timer?.invalidate(); timer = nil; startedAt = nil
        timerLabel.stringValue = "00:00"
        startButton.title = L("开始录屏")
        startButton.isBordered = true
        startButton.bezelStyle = .rounded
        startButton.layer?.backgroundColor = NSColor.clear.cgColor
        startButton.contentTintColor = nil
        startButton.attributedTitle = NSAttributedString(string: L("开始录屏"))
        timerLabel.isHidden = true
        backButton?.isHidden = false
        if let contentView { startButton.frame.origin.x = (contentView.bounds.width - startButton.frame.width) / 2 }
    }
    func close() { timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil }
}

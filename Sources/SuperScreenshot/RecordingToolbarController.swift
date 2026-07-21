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
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98)
        panel.hasShadow = true
        let stack = NSStackView()
        stack.orientation = .horizontal; stack.spacing = 12; stack.alignment = .centerY
        let back = NSButton(title: L("返回截图"), target: self, action: #selector(back))
        backButton = back
        startButton.target = self; startButton.action = #selector(toggle)
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timerLabel.isHidden = true
        stack.addArrangedSubview(back); stack.addArrangedSubview(timerLabel); stack.addArrangedSubview(startButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: CGRect(origin: .zero, size: size)); content.addSubview(stack); panel.contentView = content
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: content.centerXAnchor), stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        self.panel = panel; panel.orderFrontRegardless()
    }

    @objc private func toggle() {
        if startedAt == nil {
            startedAt = Date(); startButton.title = L("结束录屏")
            startButton.isBordered = false
            startButton.wantsLayer = true
            startButton.layer?.backgroundColor = NSColor.systemRed.cgColor
            startButton.layer?.cornerRadius = 7
            startButton.contentTintColor = .white
            startButton.attributedTitle = NSAttributedString(string: L("结束录屏"), attributes: [.foregroundColor: NSColor.white])
            timerLabel.isHidden = false; backButton?.isHidden = true
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
        startButton.layer?.backgroundColor = NSColor.clear.cgColor
        startButton.contentTintColor = nil
        startButton.attributedTitle = NSAttributedString(string: L("开始录屏"))
        timerLabel.isHidden = true
        backButton?.isHidden = false
    }
    func close() { timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil }
}

import AppKit

private final class RecordingStopButton: NSButton {
    var usesStopStyle = false {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard usesStopStyle else {
            super.draw(dirtyRect)
            return
        }
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        let fill = isHighlighted
            ? NSColor.systemRed.blended(withFraction: 0.22, of: .black)!
            : NSColor.systemRed
        fill.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(isHighlighted ? 0.16 : 0.28).setStroke()
        path.lineWidth = 1
        path.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]
        (title as NSString).draw(
            in: CGRect(x: 4, y: (bounds.height - 19) / 2 - 1, width: bounds.width - 8, height: 20),
            withAttributes: attributes
        )
    }
}

private final class DraggableRecordingToolbarView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
final class RecordingToolbarController: NSObject {
    var onStart: ((RecordingFrameRate, Int) -> Void)?
    var onStop: (() -> Void)?
    var onBack: (() -> Void)?
    var onHide: (() -> Void)?
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt: Date?
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let recordingSettingsLabel = NSTextField(labelWithString: "")
    private let startButton = RecordingStopButton(title: L("开始录屏"), target: nil, action: nil)
    private let hideToolbarButton = NSButton(title: L("隐藏工具栏"), target: nil, action: nil)
    private weak var backButton: NSButton?
    private weak var frameRateControl: NSSegmentedControl?
    private weak var bitRateSlider: NSSlider?
    private weak var bitRateLabel: NSTextField?
    private weak var bitRateValueLabel: NSTextField?
    private weak var bitRateEstimateLabel: NSTextField?
    private var supportsHighFrameRate = false
    private weak var contentView: NSView?
    private var visibleFrame = CGRect.zero
    private var recordingPixelSize = CGSize.zero
    private var maximumBitRateMbps = 6.0

    func show(in screen: NSScreen, below selection: CGRect, from sourceFrame: CGRect? = nil) {
        let size = CGSize(width: 480, height: 104)
        visibleFrame = screen.visibleFrame
        if let displayID = ScreenCapture.displayID(for: screen) {
            let xScale = CGFloat(CGDisplayPixelsWide(displayID)) / screen.frame.width
            let yScale = CGFloat(CGDisplayPixelsHigh(displayID)) / screen.frame.height
            recordingPixelSize = CGSize(width: (selection.width * xScale).rounded(.up), height: (selection.height * yScale).rounded(.up))
        } else {
            recordingPixelSize = CGSize(width: (selection.width * screen.backingScaleFactor).rounded(.up), height: (selection.height * screen.backingScaleFactor).rounded(.up))
        }
        var x = selection.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        var y = selection.minY - size.height - 12
        if y < screen.visibleFrame.minY + 8 { y = selection.maxY + 12 }
        y = min(max(y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
        let frame = CGRect(x: x,
                           y: y,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        let content = DraggableRecordingToolbarView(frame: CGRect(origin: .zero, size: size))
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
        hideToolbarButton.target = self
        hideToolbarButton.action = #selector(hideToolbar)
        hideToolbarButton.bezelStyle = .rounded
        hideToolbarButton.isHidden = true
        hideToolbarButton.frame = CGRect(x: 312, y: 14, width: 112, height: 36)
        let frameRate = NSSegmentedControl(labels: ["30", "60", "120"], trackingMode: .selectOne, target: self, action: #selector(frameRateChanged(_:)))
        frameRate.selectedSegment = 1
        frameRate.toolTip = L("录制帧率（FPS）")
        frameRate.setWidth(31, forSegment: 0)
        frameRate.setWidth(31, forSegment: 1)
        frameRate.setWidth(39, forSegment: 2)
        if #available(macOS 13.0, *) {
            supportsHighFrameRate = ScreenRecorder.supportedFrameRates(for: screen).contains(.high)
        } else {
            supportsHighFrameRate = false
        }
        if !supportsHighFrameRate {
            frameRate.setToolTip(L("当前屏幕暂不支持 120 FPS"), forSegment: 2)
        }
        let fpsLabel = NSTextField(labelWithString: "FPS")
        fpsLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fpsLabel.frame = CGRect(x: 102, y: 66, width: 28, height: 18)
        frameRate.frame = CGRect(x: 130, y: 61, width: 102, height: 28)
        frameRateControl = frameRate
        let bitrateLabel = NSTextField(labelWithString: L("码率 (Mbps)"))
        bitrateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        bitrateLabel.alignment = .right
        bitrateLabel.frame = CGRect(x: 242, y: 66, width: 88, height: 18)
        bitRateLabel = bitrateLabel
        let bitrateValue = NSTextField(labelWithString: "")
        bitrateValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        bitrateValue.textColor = .secondaryLabelColor
        bitrateValue.frame = CGRect(x: 338, y: 85, width: 36, height: 14)
        bitRateValueLabel = bitrateValue
        let bitrateEstimate = NSTextField(labelWithString: "")
        bitrateEstimate.font = .systemFont(ofSize: 10, weight: .medium)
        bitrateEstimate.textColor = .secondaryLabelColor
        bitrateEstimate.alignment = .right
        bitrateEstimate.frame = CGRect(x: 374, y: 85, width: 83, height: 14)
        bitRateEstimateLabel = bitrateEstimate
        let bitrateSlider = NSSlider(value: 1, minValue: 1, maxValue: 6, target: self, action: #selector(bitRateChanged(_:)))
        bitrateSlider.isContinuous = true
        bitrateSlider.frame = CGRect(x: 338, y: 61, width: 119, height: 24)
        bitRateSlider = bitrateSlider
        updateBitRateRange()
        updateBitRateEstimate()
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        timerLabel.isHidden = true
        timerLabel.alignment = .center
        timerLabel.frame = CGRect(x: 48, y: 23, width: 116, height: 30)
        recordingSettingsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        recordingSettingsLabel.textColor = .secondaryLabelColor
        recordingSettingsLabel.alignment = .right
        recordingSettingsLabel.isHidden = true
        recordingSettingsLabel.frame = CGRect(x: 48, y: 10, width: 116, height: 14)
        content.addSubview(back); content.addSubview(timerLabel); content.addSubview(recordingSettingsLabel); content.addSubview(fpsLabel); content.addSubview(frameRate); content.addSubview(bitrateLabel); content.addSubview(bitrateValue); content.addSubview(bitrateEstimate); content.addSubview(bitrateSlider); content.addSubview(startButton); content.addSubview(hideToolbarButton)
        panel.contentView = content
        contentView = content
        self.panel = panel
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        // Drop down from the centre of the recording toolbar's final lane.
        // This continues the editor toolbar transition without a sideways jump.
        let initialFrame = frame.offsetBy(dx: 0, dy: 14)
        panel.setFrame(initialFrame, display: false)
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
            startButton.bezelStyle = .rounded
            startButton.bezelColor = nil
            startButton.contentTintColor = nil
            startButton.usesStopStyle = true
            startButton.attributedTitle = NSAttributedString(string: L("结束录屏"))
            timerLabel.isHidden = false; backButton?.isHidden = true; frameRateControl?.isHidden = true
            bitRateSlider?.isHidden = true; bitRateLabel?.isHidden = true; bitRateValueLabel?.isHidden = true; bitRateEstimateLabel?.isHidden = true
            startButton.frame.origin.x = 188
            hideToolbarButton.isHidden = false
            compactForRecording()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateTimer() }
            let rate: RecordingFrameRate
            switch frameRateControl?.selectedSegment {
            case 0: rate = .low
            case 2: rate = .high
            default: rate = .standard
            }
            let value = min(max(bitRateSlider?.doubleValue ?? 1, 1), maximumBitRateMbps)
            recordingSettingsLabel.stringValue = String(format: "%d FPS · %.1f Mbps", rate.rawValue, value)
            recordingSettingsLabel.isHidden = false
            onStart?(rate, Int((value * 1_000_000).rounded()))
        } else { onStop?() }
    }
    @objc private func frameRateChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 2, !supportsHighFrameRate {
            sender.selectedSegment = 1
            let alert = NSAlert()
            alert.messageText = L("暂不支持 120 FPS")
            alert.informativeText = L("当前屏幕刷新率不足 120Hz，无法使用 120 FPS 录制。")
            alert.addButton(withTitle: L("好"))
            alert.runModal()
        }
        updateBitRateRange()
    }
    @objc private func bitRateChanged(_ sender: NSSlider) {
        sender.doubleValue = (min(max(sender.doubleValue, 1), maximumBitRateMbps) * 10).rounded() / 10
        updateBitRateEstimate()
    }
    private func updateBitRateRange() {
        guard let slider = bitRateSlider else { return }
        let frameRate: Double
        switch frameRateControl?.selectedSegment {
        case 0: frameRate = 30
        case 2: frameRate = 120
        default: frameRate = 60
        }
        // H.264 screen content needs about 0.14 bit per pixel per frame for
        // a high-quality ceiling. The slider remains usable from 1 Mbps and
        // never offers more than the recorder's 45 Mbps safety ceiling.
        let calculated = Double(recordingPixelSize.width * recordingPixelSize.height) * frameRate * 0.14 / 1_000_000
        maximumBitRateMbps = min(45, max(1, (calculated * 10).rounded(.up) / 10))
        slider.maxValue = maximumBitRateMbps
        slider.doubleValue = min(max(slider.doubleValue, 1), maximumBitRateMbps)
    }
    private func updateBitRateEstimate() {
        let value = min(max(bitRateSlider?.doubleValue ?? 1, 1), maximumBitRateMbps)
        let megabytesPerMinute = value * 60 / 8
        bitRateValueLabel?.stringValue = String(format: "%.1f", value)
        bitRateEstimateLabel?.stringValue = L(String(format: "1分钟约 %.0f MB", megabytesPerMinute))
    }
    private func compactForRecording() {
        guard let panel else { return }
        let size = CGSize(width: 460, height: 64)
        // Preserve the setup toolbar's visual centre after a user drag.
        // The recording controls then appear in exactly the same place,
        // without a transition that could look like an unintended jump.
        var compact = CGRect(x: panel.frame.midX - size.width / 2, y: panel.frame.midY - size.height / 2, width: size.width, height: size.height)
        compact.origin.x = min(max(compact.minX, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        compact.origin.y = min(max(compact.minY, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        panel.setFrame(compact, display: true)
    }
    private func updateTimer() { guard let startedAt else { return }; timerLabel.stringValue = String(format: "%02d:%02d", Int(Date().timeIntervalSince(startedAt)) / 60, Int(Date().timeIntervalSince(startedAt)) % 60) }
    @objc private func back() { onBack?() }
    @objc private func hideToolbar() { panel?.orderOut(nil); onHide?() }
    func recordingDidStop() {
        timer?.invalidate(); timer = nil; startedAt = nil
        timerLabel.stringValue = "00:00"
        startButton.title = L("开始录屏")
        startButton.isBordered = true
        startButton.bezelStyle = .rounded
        startButton.bezelColor = nil
        startButton.contentTintColor = nil
        startButton.usesStopStyle = false
        startButton.attributedTitle = NSAttributedString(string: L("开始录屏"))
        timerLabel.isHidden = true
        recordingSettingsLabel.isHidden = true
        hideToolbarButton.isHidden = true
        backButton?.isHidden = false
        frameRateControl?.isHidden = false
        bitRateSlider?.isHidden = false
        bitRateLabel?.isHidden = false
        bitRateValueLabel?.isHidden = false
        bitRateEstimateLabel?.isHidden = false
        if let contentView { startButton.frame.origin.x = (contentView.bounds.width - startButton.frame.width) / 2 }
    }
    func hideWhileRecording() { panel?.orderOut(nil) }
    func dismissForBack(completion: @escaping () -> Void) {
        guard let panel, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            close(); completion(); return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 14), display: true)
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.close()
                completion()
            }
        }
    }
    func close() { timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil }
}

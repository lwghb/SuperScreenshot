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
    var onManualMoveBegan: (@MainActor () -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { onHoverEnter?() }
    override func mouseExited(with event: NSEvent) { onHoverExit?() }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onManualMoveBegan?()
        super.mouseDown(with: event)
    }
}

@MainActor
final class RecordingToolbarController: NSObject {
    var onStart: (@MainActor (RecordingFrameRate, Int, Bool) -> Void)?
    var onStop: (@MainActor () -> Void)?
    var onBack: (@MainActor () -> Void)?
    var onHide: (@MainActor () -> Void)?
    private var panel: NSPanel?
    private var settingsDismissTask: Task<Void, Never>?
    private var pointerInSettings = false
    private var settingsPopover: NSPopover?
    var isSettingsVisible: Bool { settingsPopover?.isShown == true || panel?.isVisible == true }
    private var timer: Timer?
    private var startedAt: Date?
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let recordingSizeLabel = NSTextField(labelWithString: "")
    private var recordingBytesPerSecond = 0.0
    private let recordingSettingsLabel = NSTextField(labelWithString: "")
    private let startButton = RecordingStopButton(title: L("开始录屏"), target: nil, action: nil)
    private let hideToolbarButton = NSButton(title: L("隐藏工具栏"), target: nil, action: nil)
    private weak var backButton: NSButton?
    private weak var frameRateLabel: NSTextField?
    private weak var frameRateControl: NSSegmentedControl?
    private weak var bitRateSlider: NSSlider?
    private weak var bitRateLabel: NSTextField?
    private weak var bitRateValueLabel: NSTextField?
    private weak var bitRateEstimateLabel: NSTextField?
    private weak var systemAudioButton: NSButton?
    private var supportsHighFrameRate = false
    private weak var contentView: NSView?
    private var visibleFrame = CGRect.zero
    private var recordingPixelSize = CGSize.zero
    private var maximumBitRateMbps = 6.0
    private var hasUserPositionedToolbar = false
    private var isStopping = false
    private var isStarting = false
    private var settingsOnly = false
    private var preferences = RecordingPreferences()

    func show(in screen: NSScreen, below selection: CGRect, from sourceFrame: CGRect? = nil, settingsOnly: Bool = false, startImmediately: Bool = false, settingsAnchor: NSView? = nil) {
        self.settingsOnly = settingsOnly
        preferences = RecordingPreferences()
        let size = settingsOnly ? CGSize(width: 360, height: 136) : CGSize(width: 480, height: 104)
        hasUserPositionedToolbar = false
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
        if settingsOnly, let sourceFrame {
            x = min(max(sourceFrame.midX - size.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            y = sourceFrame.minY - size.height - 12
            if y < screen.visibleFrame.minY + 8 { y = sourceFrame.maxY + 12 }
            y = min(max(y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
        }
        let frame = CGRect(x: x,
                           y: y,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 5)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        let content = DraggableRecordingToolbarView(frame: CGRect(origin: .zero, size: size))
        if settingsOnly {
            content.onHoverEnter = { [weak self] in self?.pointerInSettings = true; self?.cancelSettingsDismiss() }
            content.onHoverExit = { [weak self] in self?.pointerInSettings = false; self?.scheduleSettingsDismiss() }
        }
        content.onManualMoveBegan = { [weak self] in self?.hasUserPositionedToolbar = true }
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
        startButton.isHidden = settingsOnly
        startButton.title = settingsOnly ? L("完成") : L("开始录屏")
        back.isHidden = settingsOnly
        startButton.target = self; startButton.action = #selector(toggle)
        startButton.bezelStyle = .rounded
        startButton.frame = CGRect(x: (size.width - 112) / 2, y: 14, width: 112, height: 36)
        hideToolbarButton.target = self
        hideToolbarButton.action = #selector(hideToolbar)
        hideToolbarButton.bezelStyle = .rounded
        hideToolbarButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: L("隐藏工具栏"))
        hideToolbarButton.imagePosition = .imageOnly
        hideToolbarButton.toolTip = L("隐藏工具栏")
        hideToolbarButton.isHidden = true
        hideToolbarButton.frame = CGRect(x: 312, y: 14, width: 112, height: 36)
        let systemAudio = NSButton(
            checkboxWithTitle: L("系统声音"),
            target: self,
            action: #selector(systemAudioChanged(_:))
        )
        systemAudio.font = .systemFont(ofSize: 12, weight: .medium)
        systemAudio.toolTip = L("录制电脑播放的声音，不录制麦克风")
        systemAudio.state = preferences.capturesSystemAudio ? .on : .off
        systemAudio.frame = CGRect(x: 350, y: 17, width: 108, height: 28)
        systemAudioButton = systemAudio
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
        frameRate.setEnabled(supportsHighFrameRate, forSegment: 2)
        let rate = preferences.effectiveFrameRate(supportsHighFrameRate: supportsHighFrameRate)
        frameRate.selectedSegment = rate == .low ? 0 : (rate == .high ? 2 : 1)
        if preferences.frameRate == .high && !supportsHighFrameRate {
            frameRate.toolTip = L("当前屏幕暂不支持 120 FPS")
        }
        let fpsLabel = NSTextField(labelWithString: "FPS")
        frameRateLabel = fpsLabel
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
        let bitrateSlider = NSSlider(value: preferences.bitRateMbps, minValue: 1, maxValue: 6, target: self, action: #selector(bitRateChanged(_:)))
        bitrateSlider.isContinuous = true
        bitrateSlider.frame = CGRect(x: 338, y: 61, width: 119, height: 24)
        bitRateSlider = bitrateSlider
        updateBitRateRange()
        updateBitRateEstimate()
        timerLabel.identifier = NSUserInterfaceItemIdentifier("recording.timer")
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        timerLabel.isHidden = true
        timerLabel.alignment = .center
        timerLabel.frame = CGRect(x: 48, y: 23, width: 116, height: 30)
        recordingSizeLabel.identifier = NSUserInterfaceItemIdentifier("recording.estimate")
        recordingSizeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        recordingSizeLabel.textColor = .secondaryLabelColor
        recordingSizeLabel.frame = CGRect(x: 48, y: 0, width: 130, height: 12)
        recordingSizeLabel.isHidden = true
        content.addSubview(recordingSizeLabel)
        recordingSettingsLabel.identifier = NSUserInterfaceItemIdentifier("recording.options-summary")
        recordingSettingsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        recordingSettingsLabel.textColor = .secondaryLabelColor
        recordingSettingsLabel.alignment = .right
        recordingSettingsLabel.isHidden = true
        recordingSettingsLabel.frame = CGRect(x: 48, y: 10, width: 116, height: 14)
        content.addSubview(back); content.addSubview(timerLabel); content.addSubview(recordingSettingsLabel); content.addSubview(fpsLabel); content.addSubview(frameRate); content.addSubview(bitrateLabel); content.addSubview(bitrateValue); content.addSubview(bitrateEstimate); content.addSubview(bitrateSlider); content.addSubview(startButton); content.addSubview(hideToolbarButton); content.addSubview(systemAudio)
        if settingsOnly {
            fpsLabel.frame = CGRect(x: 16, y: 100, width: 80, height: 18)
            frameRate.font = .systemFont(ofSize: 12)
            frameRate.setWidth(48, forSegment: 0)
            frameRate.setWidth(48, forSegment: 1)
            frameRate.setWidth(56, forSegment: 2)
            frameRate.frame = CGRect(x: 164, y: 94, width: 180, height: 28)
            bitrateLabel.alignment = .left
            bitrateLabel.frame = CGRect(x: 16, y: 64, width: 94, height: 18)
            bitrateValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            bitrateValue.alignment = .right
            bitrateValue.frame = CGRect(x: 112, y: 64, width: 38, height: 18)
            bitrateSlider.frame = CGRect(x: 164, y: 58, width: 180, height: 24)
            systemAudio.frame = CGRect(x: 16, y: 16, width: 128, height: 24)
            bitrateEstimate.font = .systemFont(ofSize: 11)
            bitrateEstimate.frame = CGRect(x: 160, y: 20, width: 184, height: 18)
        }
        panel.contentView = content
        contentView = content
        self.panel = panel
        if settingsOnly, let settingsAnchor {
            panel.contentView = nil
            self.panel = nil
            let controller = NSViewController()
            controller.view = content
            controller.preferredContentSize = size
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.contentSize = size
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            settingsPopover = popover
            popover.show(relativeTo: settingsAnchor.bounds, of: settingsAnchor, preferredEdge: .minY)
            return
        }
        if startImmediately {
            toggleOnMainActor()
            panel.orderFrontRegardless()
            return
        }
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

    /// Follows the editable recording border until the user manually moves
    /// this toolbar. A manual position is then respected for the session.
    func followSelectionIfNeeded(_ selection: CGRect, on screen: NSScreen) {
        guard startedAt == nil, !isStarting else { return }
        visibleFrame = screen.visibleFrame
        if let displayID = ScreenCapture.displayID(for: screen) {
            let xScale = CGFloat(CGDisplayPixelsWide(displayID)) / screen.frame.width
            let yScale = CGFloat(CGDisplayPixelsHigh(displayID)) / screen.frame.height
            recordingPixelSize = CGSize(width: (selection.width * xScale).rounded(.up), height: (selection.height * yScale).rounded(.up))
        } else {
            recordingPixelSize = CGSize(width: (selection.width * screen.backingScaleFactor).rounded(.up), height: (selection.height * screen.backingScaleFactor).rounded(.up))
        }
        bitRateSlider?.doubleValue = preferences.bitRateMbps
        updateBitRateRange()
        updateBitRateEstimate()
        guard !hasUserPositionedToolbar, let panel else { return }
        let size = panel.frame.size
        var x = selection.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        var y = selection.minY - size.height - 12
        if y < screen.visibleFrame.minY + 8 { y = selection.maxY + 12 }
        y = min(max(y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // AppKit actions enter through Objective-C. On macOS 26 the runtime's
    // executor check can crash when an @MainActor method itself is used as an
    // Objective-C selector. Keep the selector nonisolated, then hop to the
    // actor before touching any UI state.
    @objc nonisolated private func toggle() {
        Task { @MainActor [weak self] in
            self?.toggleOnMainActor()
        }
    }

    private func toggleOnMainActor() {
        if settingsOnly { onBack?(); return }
        guard !isStarting else { return }
        if startedAt == nil {
            isStarting = true
            startButton.isEnabled = false
            startButton.title = L("结束录屏")
            startButton.isBordered = true
            startButton.bezelStyle = .rounded
            startButton.bezelColor = nil
            startButton.contentTintColor = nil
            startButton.usesStopStyle = true
            startButton.attributedTitle = NSAttributedString(string: L("结束录屏"))
            timerLabel.isHidden = false; backButton?.isHidden = true; frameRateControl?.isHidden = true
            frameRateLabel?.isHidden = true
            bitRateSlider?.isHidden = true; bitRateLabel?.isHidden = true; bitRateValueLabel?.isHidden = true; bitRateEstimateLabel?.isHidden = true
            systemAudioButton?.isHidden = true
            startButton.frame.origin.x = 188
            hideToolbarButton.isHidden = false
            compactForRecording()
            let rate: RecordingFrameRate
            switch frameRateControl?.selectedSegment {
            case 0: rate = .low
            case 2: rate = .high
            default: rate = .standard
            }
            let value = min(max(bitRateSlider?.doubleValue ?? 1, 1), maximumBitRateMbps)
            recordingSettingsLabel.stringValue = String(format: "%d FPS · %.1f Mbps", rate.rawValue, value)
            recordingSettingsLabel.isHidden = false
            recordingBytesPerSecond = (value * 1_000_000 + (systemAudioButton?.state == .on ? 192_000 : 0)) / 8
            recordingSizeLabel.isHidden = false
            recordingSizeLabel.stringValue = LF("预估 %.1f MB", 0.0)
            onStart?(rate, Int((value * 1_000_000).rounded()), systemAudioButton?.state == .on)
        } else {
            // Finishing an MP4 is asynchronous. Ignore repeat clicks while
            // the writer flushes so the stop path cannot be entered twice.
            guard !isStopping else { return }
            isStopping = true
            startButton.isEnabled = false
            startButton.title = L("正在结束…")
            onStop?()
        }
    }
    @objc nonisolated private func frameRateChanged(_ sender: NSSegmentedControl) {
        Task { @MainActor [weak self, weak sender] in
            guard let sender else { return }
            self?.frameRateChangedOnMainActor(sender)
        }
    }

    private func frameRateChangedOnMainActor(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 2, !supportsHighFrameRate {
            sender.selectedSegment = 1
            let alert = NSAlert()
            alert.messageText = L("暂不支持 120 FPS")
            alert.informativeText = L("当前屏幕刷新率不足 120Hz，无法使用 120 FPS 录制。")
            alert.addButton(withTitle: L("好"))
            alert.runModal()
        }
        preferences.frameRate = sender.selectedSegment == 0 ? .low : (sender.selectedSegment == 2 ? .high : .standard)
        preferences.save()
        bitRateSlider?.doubleValue = preferences.bitRateMbps
        updateBitRateRange()
        updateBitRateEstimate()
    }
    @objc nonisolated private func bitRateChanged(_ sender: NSSlider) {
        Task { @MainActor [weak self, weak sender] in
            guard let sender else { return }
            self?.bitRateChangedOnMainActor(sender)
        }
    }

    private func bitRateChangedOnMainActor(_ sender: NSSlider) {
        sender.doubleValue = (min(max(sender.doubleValue, 1), maximumBitRateMbps) * 10).rounded() / 10
        preferences.bitRateMbps = sender.doubleValue
        preferences.save()
        updateBitRateEstimate()
    }
    @objc nonisolated private func systemAudioChanged(_ sender: NSButton) {
        Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            self.preferences.capturesSystemAudio = sender.state == .on
            self.preferences.save()
            self.updateBitRateEstimate()
        }
    }
    private func updateBitRateRange() {
        guard let slider = bitRateSlider else { return }
        let rate: RecordingFrameRate = frameRateControl?.selectedSegment == 0 ? .low : (frameRateControl?.selectedSegment == 2 ? .high : .standard)
        maximumBitRateMbps = RecordingPreferences.maximumBitRateMbps(pixelSize: recordingPixelSize, frameRate: rate)
        slider.maxValue = maximumBitRateMbps
        slider.doubleValue = min(max(slider.doubleValue, 1), maximumBitRateMbps)
    }
    private func updateBitRateEstimate() {
        let value = min(max(bitRateSlider?.doubleValue ?? 1, 1), maximumBitRateMbps)
        let audioBitRateMbps = systemAudioButton?.state == .on ? 0.192 : 0
        let megabytesPerMinute = (value + audioBitRateMbps) * 60 / 8
        bitRateValueLabel?.stringValue = String(format: "%.1f", value)
        bitRateEstimateLabel?.stringValue = L(String(format: "1分钟约 %.0f MB", megabytesPerMinute))
    }
    private func compactForRecording() {
        guard let panel else { return }
        let size = CGSize(width: 468, height: 72)
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        timerLabel.alignment = .left
        timerLabel.frame = CGRect(x: 16, y: 24, width: 92, height: 28)
        recordingSettingsLabel.alignment = .left
        recordingSettingsLabel.frame = CGRect(x: 124, y: 41, width: 148, height: 16)
        recordingSizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        recordingSizeLabel.frame = CGRect(x: 124, y: 18, width: 148, height: 16)
        startButton.frame = CGRect(x: 288, y: 18, width: 112, height: 36)
        hideToolbarButton.frame = CGRect(x: 416, y: 20, width: 36, height: 32)
        // Preserve the setup toolbar's visual centre after a user drag.
        // The recording controls then appear in exactly the same place,
        // without a transition that could look like an unintended jump.
        var compact = CGRect(x: panel.frame.midX - size.width / 2, y: panel.frame.midY - size.height / 2, width: size.width, height: size.height)
        let panelCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let currentScreenFrame = NSScreen.screens.first(where: { $0.frame.contains(panelCenter) })?.visibleFrame ?? visibleFrame
        compact.origin.x = min(max(compact.minX, currentScreenFrame.minX + 8), currentScreenFrame.maxX - size.width - 8)
        compact.origin.y = min(max(compact.minY, currentScreenFrame.minY + 8), currentScreenFrame.maxY - size.height - 8)
        panel.setFrame(compact, display: true)
    }
    private func updateTimer() {
        guard let startedAt else { return }
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        timerLabel.stringValue = String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
        recordingSizeLabel.stringValue = LF("预估 %.1f MB", elapsed * recordingBytesPerSecond / 1_000_000)
    }
    @objc nonisolated private func back() {
        Task { @MainActor [weak self] in self?.onBack?() }
    }

    @objc nonisolated private func hideToolbar() {
        Task { @MainActor [weak self] in
            self?.panel?.orderOut(nil)
            self?.onHide?()
        }
    }
    func recordingDidStart() {
        guard isStarting else { return }
        isStarting = false
        startedAt = Date()
        startButton.isEnabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateTimer() }
    }

    func recordingDidStop() {
        timer?.invalidate(); timer = nil; startedAt = nil; isStopping = false; isStarting = false
        timerLabel.stringValue = "00:00"
        startButton.title = L("开始录屏")
        startButton.isEnabled = true
        startButton.isBordered = true
        startButton.bezelStyle = .rounded
        startButton.bezelColor = nil
        startButton.contentTintColor = nil
        startButton.usesStopStyle = false
        startButton.attributedTitle = NSAttributedString(string: L("开始录屏"))
        timerLabel.isHidden = true
        recordingSettingsLabel.isHidden = true
        recordingSizeLabel.isHidden = true
        hideToolbarButton.isHidden = true
        backButton?.isHidden = false
        frameRateLabel?.isHidden = false
        frameRateControl?.isHidden = false
        bitRateSlider?.isHidden = false
        bitRateLabel?.isHidden = false
        bitRateValueLabel?.isHidden = false
        bitRateEstimateLabel?.isHidden = false
        systemAudioButton?.isHidden = false
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
    func cancelSettingsDismiss() { settingsDismissTask?.cancel() }
    func scheduleSettingsDismiss() {
        settingsDismissTask?.cancel()
        settingsDismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard let self, !self.pointerInSettings else { return }
            self.close()
        }
    }
    func close() { settingsDismissTask?.cancel(); timer?.invalidate(); timer = nil; settingsPopover?.performClose(nil); settingsPopover = nil; panel?.orderOut(nil); panel = nil }
}

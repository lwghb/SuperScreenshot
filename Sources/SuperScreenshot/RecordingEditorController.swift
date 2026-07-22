import AppKit
import AVFoundation
import AVKit
import QuartzCore

@MainActor
final class RecordingEditorController: NSObject {
    private let url: URL
    private let screen: NSScreen
    private let frameRate: Int
    private let bitRate: Int
    private let asset: AVURLAsset
    private let player: AVPlayer
    private var panel: NSPanel?
    private var trimRangeView: RecordingTrimRangeView!
    private weak var recordingInfoLabel: NSTextField?
    private weak var annotationOverlayView: RecordingAnnotationOverlayView?
    private weak var textToolButton: NSButton?
    private weak var textColorButton: NSButton?
    private weak var textBackgroundButton: NSButton?
    private weak var fontSizeSlider: NSSlider?
    private weak var deleteTextButton: NSButton?
    private weak var undoTextButton: NSButton?
    private weak var saveButton: NSButton?
    private weak var copyButton: NSButton?
    private weak var exportProgressLabel: NSTextField?
    private weak var exportProgressIndicator: NSProgressIndicator?
    private weak var annotationToolbarBackground: NSVisualEffectView?
    private weak var addAnnotationButton: NSButton?
    private var annotationToolbarViews: [NSView] = []
    private var exportProgressTimer: Timer?
    private var colorPaletteButtons: [NSButton] = []
    private var colorTarget: RecordingTextColorTarget = .text
    private var duration: Double = 0

    init(url: URL, screen: NSScreen, frameRate: Int = 60, bitRate: Int = 1_000_000) {
        self.url = url
        self.screen = screen
        self.frameRate = frameRate
        self.bitRate = bitRate
        asset = AVURLAsset(url: url)
        player = AVPlayer(url: url)
    }

    func show() {
        duration = max(asset.duration.seconds, 0.1)
        let size = CGSize(width: 820, height: 620)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L("编辑录屏")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = CGSize(width: 640, height: 460)
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
        panel.level = .floating

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let preview = AVPlayerView(frame: CGRect(x: 24, y: 194, width: 772, height: 400))
        preview.player = player
        preview.controlsStyle = .none
        preview.videoGravity = .resizeAspect
        preview.autoresizingMask = [.width, .height]
        content.addSubview(preview)

        let annotationOverlay = RecordingAnnotationOverlayView(frame: preview.frame, videoSize: videoSize)
        annotationOverlay.autoresizingMask = [.width, .height]
        annotationOverlay.onAnnotationsChanged = { [weak self] in self?.updateTextControls() }
        content.addSubview(annotationOverlay)
        annotationOverlayView = annotationOverlay

        let annotationToolbarBackground = NSVisualEffectView(frame: CGRect(x: 16, y: 106, width: 788, height: 78))
        annotationToolbarBackground.material = .hudWindow
        annotationToolbarBackground.blendingMode = .withinWindow
        annotationToolbarBackground.state = .active
        annotationToolbarBackground.wantsLayer = true
        annotationToolbarBackground.layer?.cornerRadius = 12
        annotationToolbarBackground.layer?.masksToBounds = true
        annotationToolbarBackground.isHidden = true
        content.addSubview(annotationToolbarBackground)
        self.annotationToolbarBackground = annotationToolbarBackground

        let settingsBadge = NSTextField(labelWithString: "")

        let caption = NSTextField(labelWithString: L("拖动起点和终点，选择需要保留的录屏片段"))
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        caption.frame = CGRect(x: 32, y: 48, width: 440, height: 18)
        content.addSubview(caption)

        settingsBadge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        settingsBadge.textColor = .secondaryLabelColor
        settingsBadge.alignment = .right
        settingsBadge.frame = CGRect(x: 518, y: 48, width: 278, height: 18)
        settingsBadge.autoresizingMask = [.minXMargin]
        recordingInfoLabel = settingsBadge
        content.addSubview(settingsBadge)

        let addAnnotation = NSButton(title: L("添加标注"), target: self, action: #selector(beginAnnotationEditing))
        addAnnotation.bezelStyle = .rounded
        addAnnotation.frame = CGRect(x: 350, y: 145, width: 120, height: 34)
        content.addSubview(addAnnotation)
        addAnnotationButton = addAnnotation

        let textTool = NSButton(title: "T", target: self, action: #selector(useTextTool))
        textTool.bezelStyle = .texturedRounded
        textTool.font = .boldSystemFont(ofSize: 16)
        textTool.frame = CGRect(x: 32, y: 150, width: 76, height: 26)
        textTool.frame.size.width = 40
        content.addSubview(textTool)
        textToolButton = textTool
        annotationToolbarViews.append(textTool)

        let textColor = NSButton(title: L("字色"), target: self, action: #selector(pickTextColor))
        textColor.bezelStyle = .rounded
        textColor.frame = CGRect(x: 114, y: 150, width: 54, height: 26)
        content.addSubview(textColor)
        textColorButton = textColor
        annotationToolbarViews.append(textColor)

        let background = NSButton(title: L("背景"), target: self, action: #selector(pickTextBackground))
        background.bezelStyle = .rounded
        background.frame = CGRect(x: 174, y: 150, width: 54, height: 26)
        content.addSubview(background)
        textBackgroundButton = background
        annotationToolbarViews.append(background)

        let sizeLabel = NSTextField(labelWithString: L("字号"))
        sizeLabel.font = .systemFont(ofSize: 12)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.frame = CGRect(x: 238, y: 154, width: 34, height: 18)
        content.addSubview(sizeLabel)
        annotationToolbarViews.append(sizeLabel)
        let fontSize = NSSlider(value: 18, minValue: 12, maxValue: 48, target: self, action: #selector(changeTextFontSize(_:)))
        fontSize.frame = CGRect(x: 272, y: 151, width: 84, height: 22)
        content.addSubview(fontSize)
        fontSizeSlider = fontSize
        annotationToolbarViews.append(fontSize)

        let undo = NSButton(title: L("撤销"), target: self, action: #selector(undoText))
        undo.bezelStyle = .rounded
        undo.frame = CGRect(x: 610, y: 150, width: 54, height: 26)
        content.addSubview(undo)
        undoTextButton = undo
        annotationToolbarViews.append(undo)
        let delete = NSButton(title: L("删除"), target: self, action: #selector(deleteText))
        delete.bezelStyle = .rounded
        delete.frame = CGRect(x: 670, y: 150, width: 54, height: 26)
        content.addSubview(delete)
        deleteTextButton = delete
        annotationToolbarViews.append(delete)

        for (index, mode) in [ScreenshotAnnotationMode.arrow, .rectangle, .ellipse, .mosaic].enumerated() {
            let symbol = ["arrow.down.right", "rectangle", "circle", "square.grid.3x3.fill"][index]
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(useAnnotationTool(_:)))
            button.tag = mode.rawValue
            button.bezelStyle = .texturedRounded
            button.frame = CGRect(x: 368 + CGFloat(index) * 48, y: 150, width: 40, height: 26)
            content.addSubview(button)
            annotationToolbarViews.append(button)
        }

        for (index, color) in RecordingTextOverlayView.palette.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(selectInlineColor(_:)))
            button.tag = index
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.frame = CGRect(x: 32 + CGFloat(index) * 34, y: 116, width: 26, height: 26)
            button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.cornerRadius = 5
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.separatorColor.cgColor
            button.isHidden = true
            content.addSubview(button)
            colorPaletteButtons.append(button)
            annotationToolbarViews.append(button)
        }
        let customColor = NSButton(title: L("自定义颜色"), target: self, action: #selector(showCustomTextColor))
        customColor.bezelStyle = .rounded
        customColor.frame = CGRect(x: 308, y: 116, width: 84, height: 26)
        customColor.isHidden = true
        content.addSubview(customColor)
        colorPaletteButtons.append(customColor)
        annotationToolbarViews.append(customColor)

        let trimRange = RecordingTrimRangeView(frame: CGRect(x: 32, y: 76, width: 764, height: 38))
        trimRange.duration = duration
        trimRange.end = duration
        trimRange.autoresizingMask = [.width]
        trimRange.onPreview = { [weak self] seconds in
            guard let self else { return }
            self.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            self.updateRecordingInfo()
        }
        trimRangeView = trimRange
        content.addSubview(trimRange)
        updateRecordingInfo()

        let save = NSButton(title: L("保存"), target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.frame = CGRect(x: 558, y: 18, width: 108, height: 32)
        save.autoresizingMask = [.minXMargin]
        let copy = NSButton(title: L("复制到剪贴板"), target: self, action: #selector(copyToPasteboard))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        copy.frame = CGRect(x: 678, y: 18, width: 118, height: 32)
        copy.autoresizingMask = [.minXMargin]
        content.addSubview(save)
        content.addSubview(copy)
        saveButton = save
        copyButton = copy

        let progressLabel = NSTextField(labelWithString: "")
        progressLabel.alignment = .right
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = CGRect(x: 328, y: 25, width: 216, height: 18)
        progressLabel.isHidden = true
        content.addSubview(progressLabel)
        exportProgressLabel = progressLabel
        let progress = NSProgressIndicator(frame: CGRect(x: 328, y: 18, width: 216, height: 4))
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        content.addSubview(progress)
        exportProgressIndicator = progress

        panel.contentView = content
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setAnnotationToolbarVisible(false)
        updateTextControls()
    }

    private func updateRecordingInfo() {
        let selectedDuration = max(0, (trimRangeView?.end ?? duration) - (trimRangeView?.start ?? 0))
        let estimatedMegabytes = selectedDuration * Double(bitRate) / 8_000_000
        recordingInfoLabel?.stringValue = String(format: "%d FPS · %.1f Mbps · %@ %.1f MB", frameRate, Double(bitRate) / 1_000_000, L("预计约"), estimatedMegabytes)
    }

    private var videoSize: CGSize {
        guard let track = asset.tracks(withMediaType: .video).first else { return CGSize(width: 16, height: 9) }
        let size = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    @objc private func useTextTool() {
        annotationOverlayView?.mode = .text
        colorTarget = .background
        showInlinePalette()
        updateTextControls()
    }

    @objc private func useAnnotationTool(_ sender: NSButton) {
        annotationOverlayView?.mode = ScreenshotAnnotationMode(rawValue: sender.tag) ?? .arrow
        colorPaletteButtons.forEach { $0.isHidden = true }
        updateTextControls()
    }

    @objc private func pickTextColor() {
        colorTarget = .text
        showInlinePalette()
    }

    @objc private func pickTextBackground() {
        colorTarget = .background
        showInlinePalette()
    }

    private func showInlinePalette() {
        colorPaletteButtons.forEach { $0.isHidden = false }
    }

    @objc private func selectInlineColor(_ sender: NSButton) {
        let color = RecordingTextOverlayView.palette[sender.tag]
        if colorTarget == .text { annotationOverlayView?.textColor = color }
        else { annotationOverlayView?.backgroundColor = color }
        updateTextControls()
    }

    @objc private func showCustomTextColor() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(customTextColorChanged(_:)))
        panel.color = colorTarget == .text ? (annotationOverlayView?.textColor ?? .white) : (annotationOverlayView?.backgroundColor ?? .systemRed)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customTextColorChanged(_ sender: NSColorPanel) {
        if colorTarget == .text { annotationOverlayView?.textColor = sender.color }
        else { annotationOverlayView?.backgroundColor = sender.color }
        updateTextControls()
    }

    private func showTextColorMenu(from button: NSButton?) {
        guard let button else { return }
        let menu = NSMenu()
        for color in RecordingTextOverlayView.palette {
            let item = NSMenuItem(title: "", action: #selector(selectTextColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.image = colorSwatchImage(color)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func selectTextColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        if colorTarget == .text { annotationOverlayView?.textColor = color }
        else { annotationOverlayView?.backgroundColor = color }
        updateTextControls()
    }

    @objc private func changeTextFontSize(_ sender: NSSlider) {
        annotationOverlayView?.textFontSize = CGFloat(sender.doubleValue)
        updateTextControls()
    }

    @objc private func undoText() { annotationOverlayView?.undo() }
    @objc private func deleteText() { annotationOverlayView?.deleteSelectedAnnotation() }

    private func updateTextControls() {
        guard let annotationOverlayView else { return }
        textToolButton?.contentTintColor = annotationOverlayView.mode == .text ? .systemBlue : .labelColor
        textToolButton?.state = annotationOverlayView.mode == .text ? .on : .off
        fontSizeSlider?.doubleValue = Double(annotationOverlayView.textFontSize)
        textColorButton?.contentTintColor = annotationOverlayView.textColor
        textBackgroundButton?.contentTintColor = annotationOverlayView.backgroundColor
        undoTextButton?.isEnabled = annotationOverlayView.hasAnnotations
        deleteTextButton?.isHidden = !annotationOverlayView.hasAnnotations
    }

    private func colorSwatchImage(_ color: NSColor) -> NSImage {
        let image = NSImage(size: CGSize(width: 14, height: 14))
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
        image.unlockFocus()
        return image
    }

    @objc private func save() {
        let dialog = NSSavePanel()
        dialog.allowedFileTypes = ["mp4"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let bitRateText = String(format: "%.1f", Double(bitRate) / 1_000_000)
        dialog.nameFieldStringValue = "\(formatter.string(from: Date()))_\(frameRate)fps_\(bitRateText)Mbps.mp4"
        dialog.beginSheetModal(for: panel!) { [weak self] response in
            guard let self, response == .OK, let target = dialog.url else { return }
            self.export(to: target) { result in
                switch result {
                case .success: self.close()
                case .failure(let error): self.showError(error)
                }
            }
        }
    }

    @objc private func copyToPasteboard() {
        let copiedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("superscreenshot-clip-\(UUID().uuidString).mp4")
        export(to: copiedURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let output):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([output as NSURL])
                self.close()
            case .failure(let error): self.showError(error)
            }
        }
    }

    private func export(to target: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: target) }
        // Keeping the entire recording must not introduce a second encode.
        // This preserves the original capture's exact dimensions and bitrate.
        if trimRangeView.start <= 0.001, trimRangeView.end >= duration - 0.001, annotationOverlayView?.hasAnnotations != true {
            do {
                try FileManager.default.copyItem(at: url, to: target)
                completion(.success(target))
            } catch { completion(.failure(error)) }
            return
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(NSError(domain: "SuperScreenshot.Recording", code: 20, userInfo: [NSLocalizedDescriptionKey: L("无法创建视频导出器")])))
            return
        }
        exporter.outputURL = target
        exporter.outputFileType = .mp4
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: trimRangeView.start, preferredTimescale: 600),
            end: CMTime(seconds: trimRangeView.end, preferredTimescale: 600)
        )
        exporter.videoComposition = makeAnnotationVideoComposition()
        beginExportProgress()
        exportProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self, weak exporter] _ in
            guard let self, let exporter else { return }
            self.exportProgressIndicator?.doubleValue = Double(exporter.progress)
            self.exportProgressLabel?.stringValue = String(format: "%@ %.0f%%", L("正在导出"), exporter.progress * 100)
        }
        exporter.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                self?.endExportProgress()
                switch exporter.status {
                case .completed: completion(.success(target))
                default:
                    completion(.failure(exporter.error ?? NSError(domain: "SuperScreenshot.Recording", code: 21, userInfo: [NSLocalizedDescriptionKey: L("录屏导出失败")])))
                }
                _ = self
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("录屏导出失败")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("好"))
        alert.beginSheetModal(for: panel!)
    }

    private func beginExportProgress() {
        saveButton?.isEnabled = false
        copyButton?.isEnabled = false
        exportProgressLabel?.stringValue = L("正在导出 0%")
        exportProgressLabel?.isHidden = false
        exportProgressIndicator?.doubleValue = 0
        exportProgressIndicator?.isHidden = false
    }

    private func endExportProgress() {
        exportProgressTimer?.invalidate()
        exportProgressTimer = nil
        exportProgressLabel?.isHidden = true
        exportProgressIndicator?.isHidden = true
        saveButton?.isEnabled = true
        copyButton?.isEnabled = true
    }

    private func close() { exportProgressTimer?.invalidate(); player.pause(); panel?.orderOut(nil); panel = nil }

    private func makeAnnotationVideoComposition() -> AVMutableVideoComposition? {
        guard let overlayImage = annotationOverlayView?.renderedOverlay(),
              annotationOverlayView?.hasAnnotations == true else { return nil }
        let composition = AVMutableVideoComposition(propertiesOf: asset)
        let renderSize = composition.renderSize
        guard renderSize.width > 0, renderSize.height > 0 else { return nil }
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)
        let overlayLayer = CALayer()
        overlayLayer.frame = parentLayer.bounds
        overlayLayer.contents = overlayImage
        overlayLayer.contentsGravity = .resize
        parentLayer.addSublayer(overlayLayer)
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        return composition
    }

    @objc private func beginAnnotationEditing() {
        setAnnotationToolbarVisible(true)
        annotationOverlayView?.mode = .arrow
        updateTextControls()
    }

    private func setAnnotationToolbarVisible(_ visible: Bool) {
        annotationToolbarBackground?.isHidden = !visible
        annotationToolbarViews.forEach { $0.isHidden = !visible }
        addAnnotationButton?.isHidden = visible
        colorPaletteButtons.forEach { $0.isHidden = true }
    }

}

// Recording annotations deliberately use the screenshot editor canvas itself.
// It keeps text input, shape resizing, mosaic sampling and rendering identical
// across still images and video previews.
@MainActor
private final class RecordingAnnotationOverlayView: NSView {
    let canvas: ScreenshotEditorView
    var onAnnotationsChanged: (() -> Void)?

    init(frame: CGRect, videoSize: CGSize) {
        let image = Self.transparentImage(size: videoSize)
        canvas = ScreenshotEditorView(frame: CGRect(origin: .zero, size: frame.size), image: image, imagePadding: 0)
        super.init(frame: frame)
        canvas.autoresizingMask = [.width, .height]
        canvas.drawsWorkspace = false
        canvas.drawsBaseImage = false
        canvas.showsImageBorder = false
        canvas.layer?.backgroundColor = NSColor.clear.cgColor
        canvas.mode = .text
        canvas.strokeColor = .systemRed
        canvas.textColor = .white
        canvas.textBackgroundColor = .systemRed
        canvas.onAnnotationAvailabilityChanged = { [weak self] _ in self?.onAnnotationsChanged?() }
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var mode: ScreenshotAnnotationMode { get { canvas.mode } set { canvas.mode = newValue } }
    var textColor: NSColor { get { canvas.textColor } set { canvas.textColor = newValue } }
    var backgroundColor: NSColor { get { canvas.textBackgroundColor } set { canvas.textBackgroundColor = newValue } }
    var textFontSize: CGFloat { get { canvas.textFontSize } set { canvas.textFontSize = newValue } }
    var hasAnnotations: Bool { canvas.hasAnnotations }

    func undo() { canvas.undo(); onAnnotationsChanged?() }
    func deleteSelectedAnnotation() { canvas.deleteSelectedAnnotation(); onAnnotationsChanged?() }
    func renderedOverlay() -> CGImage? { canvas.renderedImage() }

    private static func transparentImage(size: CGSize) -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

private enum RecordingTextColorTarget { case text, background }

private struct RecordingTextAnnotation {
    var text: String
    var origin: CGPoint // normalized, bottom-left corner of the text background
    var fontRatio: CGFloat
    var textColor: NSColor
    var backgroundColor: NSColor
}

@MainActor
private final class RecordingTextOverlayView: NSView, NSTextViewDelegate {
    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
    let videoSize: CGSize
    var textMode = false { didSet { needsDisplay = true } }
    var textColor: NSColor = .white { didSet { updateActiveTextStyle(); recolorSelected() } }
    var backgroundColor: NSColor = .systemRed { didSet { updateActiveTextStyle(); recolorSelected() } }
    var textFontSize: CGFloat = 18 { didSet { updateActiveTextStyle(); resizeActiveTextView() } }
    var onAnnotationsChanged: (() -> Void)?
    private(set) var annotations: [RecordingTextAnnotation] = [] { didSet { needsDisplay = true; onAnnotationsChanged?() } }
    private var selectedIndex: Int? { didSet { needsDisplay = true; onAnnotationsChanged?() } }
    private var activeTextView: NSTextView?
    private var activeAnchor: CGPoint?
    private var movingIndex: Int?
    private var moveStart: CGPoint?

    init(frame: CGRect, videoSize: CGSize) {
        self.videoSize = videoSize
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    var canUndo: Bool { !annotations.isEmpty }
    var hasSelection: Bool { selectedIndex != nil }

    private var videoRect: CGRect {
        let scale = min(bounds.width / max(videoSize.width, 1), bounds.height / max(videoSize.height, 1))
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private var fontRatio: CGFloat { textFontSize / max(videoRect.width, 1) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if activeTextView != nil {
            commitActiveText()
            window?.makeFirstResponder(self)
            return
        }
        if let index = annotationIndex(at: point) {
            selectedIndex = index; movingIndex = index; moveStart = point; needsDisplay = true; return
        }
        guard textMode, videoRect.contains(point) else { selectedIndex = nil; needsDisplay = true; return }
        beginTextInput(at: point)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let index = movingIndex, let start = moveStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = (point.x - start.x) / max(videoRect.width, 1)
        let dy = (point.y - start.y) / max(videoRect.height, 1)
        annotations[index].origin.x = min(max(0, annotations[index].origin.x + dx), 1)
        annotations[index].origin.y = min(max(0, annotations[index].origin.y + dy), 1)
        moveStart = point
    }
    override func mouseUp(with event: NSEvent) { movingIndex = nil; moveStart = nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { deleteSelectedAnnotation() }
        else { super.keyDown(with: event) }
    }

    func undo() {
        commitActiveText()
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        selectedIndex = annotations.isEmpty ? nil : annotations.count - 1
        onAnnotationsChanged?()
    }

    func deleteSelectedAnnotation() {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
        annotations.remove(at: selectedIndex)
        self.selectedIndex = annotations.isEmpty ? nil : min(selectedIndex, annotations.count - 1)
        onAnnotationsChanged?()
    }

    private func beginTextInput(at point: CGPoint) {
        let textView = NSTextView(frame: CGRect(x: point.x, y: point.y, width: 24, height: 24))
        textView.isRichText = false; textView.drawsBackground = false; textView.isHorizontallyResizable = false; textView.isVerticallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0; textView.textContainer?.maximumNumberOfLines = 1; textView.textContainer?.lineBreakMode = .byClipping
        textView.delegate = self; textView.wantsLayer = true
        addSubview(textView)
        activeTextView = textView; activeAnchor = point
        updateActiveTextStyle(); window?.makeFirstResponder(textView)
    }
    func textDidChange(_ notification: Notification) { resizeActiveTextView() }
    func textDidEndEditing(_ notification: Notification) { commitActiveText() }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitActiveText(); window?.makeFirstResponder(self); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { discardActiveText(); window?.makeFirstResponder(self); return true }
        return false
    }
    private func updateActiveTextStyle() {
        guard let textView = activeTextView else { return }
        textView.font = .systemFont(ofSize: textFontSize, weight: .semibold); textView.textColor = textColor; textView.insertionPointColor = textColor
        textView.layer?.backgroundColor = backgroundColor.withAlphaComponent(0.9).cgColor; textView.layer?.cornerRadius = textFontSize * 0.35
    }
    private func resizeActiveTextView() {
        guard let textView = activeTextView, let anchor = activeAnchor else { return }
        let font = NSFont.systemFont(ofSize: textFontSize, weight: .semibold)
        let width = NSAttributedString(string: textView.string, attributes: [.font: font]).size().width
        let padding = textFontSize * 0.35
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font) + padding * 2)
        textView.frame = CGRect(
            x: anchor.x,
            y: anchor.y - height,
            width: min(max(width + padding * 2, padding * 2 + 2), max(padding * 2 + 2, videoRect.maxX - anchor.x)),
            height: height
        )
        textView.textContainerInset = CGSize(width: padding, height: padding)
    }
    private func commitActiveText() {
        guard let textView = activeTextView, let anchor = activeAnchor else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let origin = CGPoint(x: (anchor.x - videoRect.minX) / videoRect.width, y: (anchor.y - videoRect.minY) / videoRect.height)
            annotations.append(RecordingTextAnnotation(text: text, origin: origin, fontRatio: fontRatio, textColor: textColor, backgroundColor: backgroundColor))
            selectedIndex = annotations.count - 1
        }
        textView.removeFromSuperview(); activeTextView = nil; activeAnchor = nil
    }
    private func discardActiveText() { activeTextView?.removeFromSuperview(); activeTextView = nil; activeAnchor = nil }
    private func recolorSelected() {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
        annotations[selectedIndex].textColor = textColor; annotations[selectedIndex].backgroundColor = backgroundColor; annotations[selectedIndex].fontRatio = fontRatio
    }
    private func annotationRect(_ annotation: RecordingTextAnnotation) -> CGRect {
        let fontSize = annotation.fontRatio * videoRect.width; let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let textSize = NSAttributedString(string: annotation.text, attributes: [.font: font]).size(); let padding = fontSize * 0.35
        let height = NSLayoutManager().defaultLineHeight(for: font) + padding * 2
        return CGRect(x: videoRect.minX + annotation.origin.x * videoRect.width, y: videoRect.minY + annotation.origin.y * videoRect.height - height, width: textSize.width + padding * 2, height: height)
    }
    private func annotationIndex(at point: CGPoint) -> Int? { annotations.indices.reversed().first { annotationRect(annotations[$0]).insetBy(dx: -8, dy: -8).contains(point) } }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, annotation) in annotations.enumerated() {
            let rect = annotationRect(annotation); let font = NSFont.systemFont(ofSize: annotation.fontRatio * videoRect.width, weight: .semibold); let padding = font.pointSize * 0.35
            annotation.backgroundColor.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect: rect, xRadius: padding, yRadius: padding).fill()
            NSAttributedString(string: annotation.text, attributes: [.font: font, .foregroundColor: annotation.textColor]).draw(at: CGPoint(x: rect.minX + padding, y: rect.minY + padding))
            if index == selectedIndex { NSColor.systemBlue.setStroke(); let path = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2)); path.lineWidth = 1.5; path.stroke() }
        }
        _ = context
    }
}

@MainActor
private final class RecordingTrimRangeView: NSView {
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var start: Double = 0 { didSet { needsDisplay = true } }
    var end: Double = 1 { didSet { needsDisplay = true } }
    var onPreview: ((Double) -> Void)?
    private enum DragTarget { case start, end }
    private var dragTarget: DragTarget?

    override func draw(_ dirtyRect: NSRect) {
        let track = CGRect(x: 8, y: bounds.midY - 3, width: bounds.width - 16, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let startX = position(for: start)
        let endX = position(for: end)
        let selection = CGRect(x: startX, y: track.minY, width: max(1, endX - startX), height: track.height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: selection, xRadius: 3, yRadius: 3).fill()
        for x in [startX, endX] {
            let handle = CGRect(x: x - 7, y: bounds.midY - 11, width: 14, height: 22)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 7, yRadius: 7).fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let line = NSBezierPath(); line.move(to: CGPoint(x: x - 2, y: bounds.midY - 5)); line.line(to: CGPoint(x: x - 2, y: bounds.midY + 5)); line.move(to: CGPoint(x: x + 2, y: bounds.midY - 5)); line.line(to: CGPoint(x: x + 2, y: bounds.midY + 5)); line.lineWidth = 1; line.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        dragTarget = abs(x - position(for: start)) <= abs(x - position(for: end)) ? .start : .end
        update(at: x)
    }
    override func mouseDragged(with event: NSEvent) { update(at: convert(event.locationInWindow, from: nil).x) }
    override func mouseUp(with event: NSEvent) { dragTarget = nil }

    private func update(at x: CGFloat) {
        guard let dragTarget else { return }
        let value = max(0, min(duration, Double((x - 8) / max(1, bounds.width - 16)) * duration))
        let minimumLength = min(0.1, duration)
        switch dragTarget {
        case .start: start = min(value, end - minimumLength); onPreview?(start)
        case .end: end = max(value, start + minimumLength); onPreview?(end)
        }
    }

    private func position(for value: Double) -> CGFloat { 8 + CGFloat(value / max(duration, 0.001)) * (bounds.width - 16) }
}

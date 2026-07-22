import AppKit
import AVFoundation
import AVKit
import QuartzCore

@MainActor
final class RecordingEditorController: NSObject, NSWindowDelegate {
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
    private weak var saveButton: NSButton?
    private weak var copyButton: NSButton?
    private weak var exportProgressLabel: NSTextField?
    private weak var exportProgressIndicator: NSProgressIndicator?
    private weak var annotationToolbar: SharedAnnotationToolbar?
    private weak var addAnnotationButton: NSButton?
    private weak var previewView: AVPlayerView?
    private weak var trimCaptionLabel: NSTextField?
    private var exportProgressTimer: Timer?
    private var colorTarget: SharedAnnotationColorTarget = .text
    private var duration: Double = 0
    private var annotationEditorExpanded = false

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
        let size = CGSize(width: 820, height: 580)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L("编辑录屏")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = CGSize(width: 640, height: 460)
        panel.delegate = self
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
        panel.level = .floating

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let preview = AVPlayerView(frame: CGRect(x: 24, y: 160, width: 772, height: 400))
        preview.player = player
        preview.controlsStyle = .none
        preview.videoGravity = .resizeAspect
        // Keep the preview's top edge fixed when the editor is resized.  The
        // former height-autoresize behaviour anchored its bottom edge and
        // pushed the upper part of the video out of the visible content area.
        preview.autoresizingMask = [.width, .minYMargin]
        content.addSubview(preview)
        previewView = preview

        let annotationOverlay = RecordingAnnotationOverlayView(frame: preview.frame, videoSize: videoSize)
        annotationOverlay.autoresizingMask = [.width, .minYMargin]
        annotationOverlay.onAnnotationsChanged = { [weak self] in self?.updateTextControls() }
        content.addSubview(annotationOverlay)
        annotationOverlayView = annotationOverlay

        let toolbar = SharedAnnotationToolbar(
            frame: CGRect(x: 16, y: 74, width: 788, height: 100),
            showsCaptureActions: false,
            showsFinish: false
        )
        toolbar.isHidden = true
        toolbar.autoresizingMask = [.width]
        toolbar.onDelete = { [weak self] in self?.annotationOverlayView?.deleteSelectedAnnotation() }
        toolbar.onUndo = { [weak self] in self?.annotationOverlayView?.undo() }
        toolbar.onMode = { [weak self] mode in
            self?.annotationOverlayView?.mode = mode
            self?.colorTarget = mode == .text ? .textBackground : .stroke
            self?.updateTextControls()
        }
        toolbar.onColorTarget = { [weak self] target in
            self?.annotationOverlayView?.mode = .text
            self?.colorTarget = target
            self?.updateTextControls()
        }
        toolbar.onFontSize = { [weak self] size in
            self?.annotationOverlayView?.textFontSize = size
            self?.updateTextControls()
        }
        toolbar.onColor = { [weak self] color in self?.applyAnnotationColor(color) }
        toolbar.onCustomColor = { [weak self] in self?.showCustomTextColor() }
        content.addSubview(toolbar)
        annotationToolbar = toolbar

        let settingsBadge = NSTextField(labelWithString: "")

        let caption = NSTextField(labelWithString: L("拖动起点和终点，选择需要保留的录屏片段"))
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        caption.frame = CGRect(x: 32, y: 88, width: 440, height: 18)
        content.addSubview(caption)
        trimCaptionLabel = caption

        settingsBadge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        settingsBadge.textColor = .secondaryLabelColor
        settingsBadge.alignment = .right
        settingsBadge.frame = CGRect(x: 518, y: 88, width: 278, height: 18)
        settingsBadge.autoresizingMask = [.minXMargin]
        recordingInfoLabel = settingsBadge
        content.addSubview(settingsBadge)

        let addAnnotation = NSButton(title: L("添加标注"), target: self, action: #selector(beginAnnotationEditing))
        addAnnotation.bezelStyle = .rounded
        addAnnotation.frame = CGRect(x: 350, y: 46, width: 120, height: 34)
        content.addSubview(addAnnotation)
        addAnnotationButton = addAnnotation


        let trimRange = RecordingTrimRangeView(frame: CGRect(x: 32, y: 114, width: 764, height: 38))
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
        save.frame = CGRect(x: 558, y: 22, width: 108, height: 32)
        save.autoresizingMask = [.minXMargin]
        let copy = NSButton(title: L("复制到剪贴板"), target: self, action: #selector(copyToPasteboard))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        copy.frame = CGRect(x: 678, y: 22, width: 118, height: 32)
        copy.autoresizingMask = [.minXMargin]
        content.addSubview(save)
        content.addSubview(copy)
        saveButton = save
        copyButton = copy

        let progressLabel = NSTextField(labelWithString: "")
        progressLabel.alignment = .right
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = CGRect(x: 328, y: 29, width: 216, height: 18)
        progressLabel.isHidden = true
        content.addSubview(progressLabel)
        exportProgressLabel = progressLabel
        let progress = NSProgressIndicator(frame: CGRect(x: 328, y: 22, width: 216, height: 4))
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
        layoutEditorContent()
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

    private func applyAnnotationColor(_ color: NSColor) {
        switch colorTarget {
        case .stroke: annotationOverlayView?.strokeColor = color
        case .text: annotationOverlayView?.textColor = color
        case .textBackground: annotationOverlayView?.backgroundColor = color
        }
        updateTextControls()
    }

    @objc private func showCustomTextColor() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(customTextColorChanged(_:)))
        switch colorTarget {
        case .stroke: panel.color = annotationOverlayView?.strokeColor ?? .systemRed
        case .text: panel.color = annotationOverlayView?.textColor ?? .white
        case .textBackground: panel.color = annotationOverlayView?.backgroundColor ?? .systemRed
        }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customTextColorChanged(_ sender: NSColorPanel) {
        applyAnnotationColor(sender.color)
    }

    private func updateTextControls() {
        guard let annotationOverlayView else { return }
        annotationToolbar?.update(
            canvas: annotationOverlayView.canvas,
            mode: annotationOverlayView.mode,
            colorTarget: colorTarget,
            hasAnnotations: annotationOverlayView.hasAnnotations
        )
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
        setAnnotationEditorExpanded(true)
        setAnnotationToolbarVisible(true)
        annotationOverlayView?.mode = .arrow
        colorTarget = .stroke
        updateTextControls()
    }

    private func setAnnotationToolbarVisible(_ visible: Bool) {
        annotationToolbar?.isHidden = !visible
        addAnnotationButton?.isHidden = visible
    }

    /// The editor only grows when annotation controls are actually requested.
    /// Before that it occupies one compact “添加标注” row, rather than reserving
    /// an empty toolbar-sized hole below the trim range.
    private func setAnnotationEditorExpanded(_ expanded: Bool) {
        guard let panel else { return }
        annotationEditorExpanded = expanded
        let offset: CGFloat = expanded ? 100 : 0
        let targetSize = CGSize(width: 820, height: 580 + offset)
        if panel.contentView?.bounds.size != targetSize {
            let frame = panel.frame
            panel.setContentSize(targetSize)
            panel.setFrameOrigin(CGPoint(x: frame.minX, y: frame.maxY - targetSize.height))
        }
        layoutEditorContent()
    }

    private func layoutEditorContent() {
        guard let content = panel?.contentView,
              let preview = previewView,
              let overlay = annotationOverlayView,
              let caption = trimCaptionLabel,
              let info = recordingInfoLabel else { return }
        let offset: CGFloat = annotationEditorExpanded ? 100 : 0
        let side: CGFloat = 24
        let previewBottom: CGFloat = 160 + offset
        // The preview always keeps a 20pt top inset.  When the user makes the
        // panel shorter, its height shrinks instead of being clipped.
        let previewHeight = max(150, content.bounds.height - previewBottom - 20)
        preview.frame = CGRect(x: side, y: previewBottom, width: max(1, content.bounds.width - side * 2), height: previewHeight)
        overlay.frame = preview.frame
        trimRangeView.frame = CGRect(x: 32, y: 114 + offset, width: max(1, content.bounds.width - 64), height: 38)
        caption.frame = CGRect(x: 32, y: 88 + offset, width: max(1, content.bounds.width * 0.58), height: 18)
        info.frame = CGRect(x: content.bounds.width * 0.60, y: 88 + offset, width: max(1, content.bounds.width * 0.36), height: 18)
        annotationToolbar?.frame = CGRect(x: 16, y: 74, width: max(1, content.bounds.width - 32), height: 100)
    }

    func windowDidResize(_ notification: Notification) {
        layoutEditorContent()
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
    var strokeColor: NSColor { get { canvas.strokeColor } set { canvas.strokeColor = newValue } }
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

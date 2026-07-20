import AppKit
import CoreGraphics

enum ScreenshotAnnotationMode: Int, CaseIterable {
    case arrow = 0
    case text = 1
    case rectangle = 2
    case ellipse = 3
    case mosaic = 4
}

private enum ColorTarget {
    case stroke
    case text
    case textBackground
}

@MainActor
final class ScreenshotEditorController: NSObject {
    var onFinish: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?

    private let image: CGImage
    private let initialMode: ScreenshotAnnotationMode
    private let screen: NSScreen?
    private var window: NSWindow?
    private var canvas: ScreenshotEditorView?
    private var colorTarget: ColorTarget = .stroke
    private var paletteStack: NSStackView?
    private var arrowButton: NSButton?
    private var textToolButton: NSButton?
    private var rectangleButton: NSButton?
    private var ellipseButton: NSButton?
    private var textColorButton: NSButton?
    private var backgroundColorButton: NSButton?
    private weak var activeColorPanel: NSColorPanel?
    private var colorPanelClickMonitor: Any?
    private let defaults = UserDefaults.standard

    init(image: CGImage, initialMode: ScreenshotAnnotationMode, screen: NSScreen? = nil) {
        self.image = image
        self.initialMode = initialMode
        self.screen = screen
    }

    func show() {
        let imageSize = CGSize(width: image.width, height: image.height)
        let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let maxSize = CGSize(width: min(screenFrame.width - 120, imageSize.width), height: min(screenFrame.height - 190, imageSize.height))
        let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height, 1)
        let canvasSize = CGSize(width: max(560, imageSize.width * scale), height: max(300, imageSize.height * scale))
        let toolbarHeight: CGFloat = 108
        let windowSize = CGSize(width: canvasSize.width, height: canvasSize.height + toolbarHeight)
        let origin = CGPoint(x: screenFrame.midX - windowSize.width / 2, y: screenFrame.midY - windowSize.height / 2)

        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("编辑截图")
        window.minSize = CGSize(width: 560, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: CGRect(origin: .zero, size: windowSize))
        let toolbar = NSStackView(frame: CGRect(x: 12, y: windowSize.height - 58, width: windowSize.width - 24, height: 44))
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        let palette = NSStackView(frame: CGRect(x: 12, y: windowSize.height - 98, width: windowSize.width - 24, height: 32))
        palette.orientation = .horizontal
        palette.spacing = 8
        palette.alignment = .centerY
        palette.distribution = .gravityAreas
        palette.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        palette.wantsLayer = true
        palette.layer?.cornerRadius = 8
        palette.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        palette.isHidden = true
        paletteStack = palette

        let editor = ScreenshotEditorView(frame: CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height), image: image)
        editor.autoresizingMask = [.width, .height]
        editor.mode = initialMode
        editor.strokeColor = loadColor("annotation.strokeColor", fallback: .systemRed)
        editor.textColor = loadColor("annotation.textColor", fallback: .white)
        editor.textBackgroundColor = loadColor("annotation.textBackgroundColor", fallback: .systemRed)
        canvas = editor

        let arrow = iconButton("arrow.down.right", action: #selector(useArrow(_:)))
        let textTool = iconButton(image: textAnnotationIcon(), action: #selector(useText(_:)))
        let rectangle = iconButton("rectangle", action: #selector(useRectangle(_:)))
        let ellipse = iconButton("circle", action: #selector(useEllipse(_:)))
        arrowButton = arrow
        textToolButton = textTool
        rectangleButton = rectangle
        ellipseButton = ellipse
        toolbar.addArrangedSubview(arrow)
        toolbar.addArrangedSubview(textTool)
        toolbar.addArrangedSubview(rectangle)
        toolbar.addArrangedSubview(ellipse)
        let text = toolbarButton(L("字色"), action: #selector(pickTextColor(_:)))
        let background = toolbarButton(L("背景色"), action: #selector(pickTextBackgroundColor(_:)))
        textColorButton = text
        backgroundColorButton = background
        toolbar.addArrangedSubview(text)
        toolbar.addArrangedSubview(background)
        toolbar.addArrangedSubview(toolbarButton(L("撤销"), action: #selector(undo)))
        toolbar.addArrangedSubview(NSView())
        let finish = ColoredTitleButton(title: L("完成"), fillColor: .systemGreen, textColor: .white, target: self, action: #selector(finish))
        finish.keyEquivalent = "\r"
        toolbar.addArrangedSubview(finish)
        toolbar.setHuggingPriority(.defaultLow, for: .horizontal)
        updateColorButtons(for: initialMode)
        rebuildPalette()
        updateToolButtonColors()
        showPalette(initialMode == .text ? .textBackground : .stroke)

        content.addSubview(editor)
        content.addSubview(palette)
        content.addSubview(toolbar)
        window.contentView = content
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        NSColorPanel.shared.setTarget(nil)
        window?.orderOut(nil)
        window = nil
        canvas = nil
    }

    private func toolbarButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func iconButton(_ symbol: String, action: Selector) -> NSButton {
        iconButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), action: action)
    }

    private func iconButton(image: NSImage, action: Selector) -> NSButton {
        let button = ColorIndicatorButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = NSColor.controlColor.cgColor
        button.layer?.borderWidth = 0
        button.layer?.borderColor = NSColor.clear.cgColor
        button.layer?.shadowOpacity = 0.0
        button.contentTintColor = .labelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    @objc private func useArrow(_ sender: NSButton) {
        canvas?.mode = .arrow
        updateColorButtons(for: .arrow)
        showPalette(.stroke)
    }

    @objc private func useRectangle(_ sender: NSButton) {
        canvas?.mode = .rectangle
        updateColorButtons(for: .rectangle)
        showPalette(.stroke)
    }

    @objc private func useEllipse(_ sender: NSButton) {
        canvas?.mode = .ellipse
        updateColorButtons(for: .ellipse)
        showPalette(.stroke)
    }

    @objc private func useText(_ sender: NSButton) {
        canvas?.mode = .text
        canvas?.pendingText = nil
        updateColorButtons(for: .text)
        showPalette(.textBackground)
    }

    private func updateColorButtons(for mode: ScreenshotAnnotationMode) {
        let isText = mode == .text
        textColorButton?.isHidden = !isText
        backgroundColorButton?.isHidden = !isText
        updateToolButtonColors()
    }

    @objc private func pickTextColor(_ sender: NSButton) { showPalette(.text) }
    @objc private func pickTextBackgroundColor(_ sender: NSButton) { showPalette(.textBackground) }

    private func showPalette(_ target: ColorTarget) {
        colorTarget = target
        rebuildPalette()
        paletteStack?.isHidden = false
    }

    private func rebuildPalette() {
        guard let paletteStack else { return }
        for view in paletteStack.arrangedSubviews {
            paletteStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
        let selectedColor = currentColor(for: colorTarget)
        for color in colors {
            let button = ColorSwatchButton(color: color, target: self, action: #selector(choosePaletteColor(_:)))
            button.isSelectedColor = colorsMatch(color, selectedColor)
            paletteStack.addArrangedSubview(button)
        }
        let more = NSButton(title: L("自定义颜色"), target: self, action: #selector(showMoreColors))
        more.bezelStyle = .rounded
        paletteStack.addArrangedSubview(more)
    }

    @objc private func choosePaletteColor(_ sender: ColorSwatchButton) {
        apply(color: sender.color)
    }

    @objc private func showMoreColors() {
        showColorPanel(colorTarget)
    }

    private func showColorPanel(_ target: ColorTarget) {
        colorTarget = target
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.color = currentColor(for: target)
        if let window {
            panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        }
        if let screen {
            positionLegacyColorPanel(panel, on: screen)
        }
        activeColorPanel = panel
        installColorPanelClickMonitor(for: panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func currentColor(for target: ColorTarget) -> NSColor {
        guard let canvas else { return .systemRed }
        switch target {
        case .stroke: return canvas.strokeColor
        case .text: return canvas.textColor
        case .textBackground: return canvas.textBackgroundColor
        }
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        apply(color: sender.color)
    }

    private func installColorPanelClickMonitor(for panel: NSColorPanel) {
        if let colorPanelClickMonitor {
            NSEvent.removeMonitor(colorPanelClickMonitor)
        }
        colorPanelClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            if event.window !== panel {
                self?.closeColorPanel()
            }
            return event
        }
    }

    private func closeColorPanel() {
        if let colorPanelClickMonitor {
            NSEvent.removeMonitor(colorPanelClickMonitor)
            self.colorPanelClickMonitor = nil
        }
        activeColorPanel?.orderOut(nil)
        activeColorPanel = nil
    }

    private func apply(color: NSColor) {
        guard let canvas else { return }
        switch colorTarget {
        case .stroke:
            canvas.strokeColor = color
            saveColor(color, key: "annotation.strokeColor")
        case .text:
            canvas.textColor = color
            saveColor(color, key: "annotation.textColor")
        case .textBackground:
            canvas.textBackgroundColor = color
            saveColor(color, key: "annotation.textBackgroundColor")
        }
        canvas.applyColorToSelectedAnnotation(color, target: colorTarget)
        updateToolButtonColors()
        rebuildPalette()
    }

    private func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.deviceRGB),
              let b = rhs.usingColorSpace(.deviceRGB) else {
            return lhs == rhs
        }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
            && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }

    private func saveColor(_ color: NSColor, key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadColor(_ key: String, fallback: NSColor) -> NSColor {
        guard let data = defaults.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return fallback
        }
        return color
    }

    private func updateToolButtonColors() {
        let stroke = canvas?.strokeColor ?? .systemRed
        let mode = canvas?.mode ?? .arrow
        applyColorBars(to: arrowButton, bottom: stroke, selected: mode == .arrow)
        applyColorBars(to: rectangleButton, bottom: stroke, selected: mode == .rectangle)
        applyColorBars(to: ellipseButton, bottom: stroke, selected: mode == .ellipse)
        applyColorBars(to: textToolButton, top: canvas?.textColor ?? .white, bottom: canvas?.textBackgroundColor ?? .systemRed, selected: mode == .text)
    }

    private func applyColorBars(to button: NSButton?, top: NSColor? = nil, bottom: NSColor? = nil, selected: Bool = false) {
        if let indicatorButton = button as? ColorIndicatorButton {
            indicatorButton.topColor = top
            indicatorButton.bottomColor = bottom
            indicatorButton.isSelectedTool = selected
            indicatorButton.needsDisplay = true
        }
        guard let layer = button?.layer else { return }
        let glow = GlowStyle.current
        let oldOpacity = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        layer.backgroundColor = NSColor.controlColor.cgColor
        layer.borderWidth = selected ? 2 : 0
        layer.borderColor = selected ? glow.color.cgColor : NSColor.clear.cgColor
        layer.masksToBounds = false
        layer.shadowColor = glow.color.cgColor
        layer.shadowOpacity = selected ? glow.opacity : 0.0
        layer.shadowRadius = selected ? glow.radius : 0
        layer.shadowOffset = .zero
        layer.shadowPath = CGPath(roundedRect: button?.bounds.insetBy(dx: -1, dy: -1) ?? .zero, cornerWidth: 8, cornerHeight: 8, transform: nil)
        if selected && oldOpacity < glow.opacity {
            let animation = CABasicAnimation(keyPath: "shadowOpacity")
            animation.fromValue = oldOpacity
            animation.toValue = glow.opacity
            animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "selectedToolGlow")
        }
        button?.contentTintColor = .labelColor
    }

    @objc private func undo() { canvas?.undo() }

    @objc private func finish() {
        guard let rendered = canvas?.renderedImage() else { return }
        closeColorPanel()
        onFinish?(rendered)
    }
}

extension ScreenshotEditorController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        closeColorPanel()
        onCancel?()
    }
}

@MainActor
private struct GlowStyle {
    let color: NSColor
    let opacity: Float
    let radius: CGFloat

    static var current: GlowStyle {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if appearance == .aqua {
            return GlowStyle(color: NSColor(calibratedRed: 0.0, green: 0.42, blue: 1.0, alpha: 1), opacity: 1.0, radius: 4)
        } else {
            return GlowStyle(color: .systemBlue, opacity: 1.0, radius: 4)
        }
    }
}

private enum ScreenshotAnnotation {
    case arrow(start: CGPoint, end: CGPoint, color: NSColor)
    case rectangle(CGRect, color: NSColor)
    case ellipse(CGRect, color: NSColor)
    case text(String, origin: CGPoint, fontSize: CGFloat, textColor: NSColor, backgroundColor: NSColor)
    case mosaic(points: [CGPoint], brushWidth: CGFloat)
}

private enum AnnotationResizeHandle: CaseIterable {
    case arrowStart, arrowEnd
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

private final class ColorIndicatorButton: NSButton {
    var topColor: NSColor?
    var bottomColor: NSColor?
    var isSelectedTool = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBar(color: topColor, y: bounds.minY + 4)
        drawBar(color: bottomColor, y: bounds.maxY - 6)
    }

    private func drawBar(color: NSColor?, y: CGFloat) {
        guard let color else { return }
        let width = min(22, max(16, bounds.width - 12))
        let rect = CGRect(x: (bounds.width - width) / 2, y: y, width: width, height: 2)
        NSColor.controlBackgroundColor.withAlphaComponent(0.75).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 1.5, yRadius: 1.5)
        outline.lineWidth = 1
        outline.stroke()
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }
}

private final class ColorSwatchButton: NSButton {
    let color: NSColor
    var isSelectedColor = false {
        didSet { updateGlow(animated: true) }
    }

    init(color: NSColor, target: AnyObject?, action: Selector?) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        self.target = target
        self.action = action
        title = ""
        image = nil
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = color.cgColor
        layer?.masksToBounds = false
        let glow = GlowStyle.current
        layer?.shadowColor = glow.color.cgColor
        layer?.shadowRadius = glow.radius
        layer?.shadowOffset = .zero
        layer?.shadowOpacity = 0
        setContentHuggingPriority(.required, for: .horizontal)
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func updateGlow(animated: Bool) {
        guard let layer else { return }
        let glow = GlowStyle.current
        let oldOpacity = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        let newOpacity: Float = isSelectedColor ? glow.opacity : 0
        layer.shadowColor = glow.color.cgColor
        layer.shadowOpacity = newOpacity
        layer.shadowRadius = isSelectedColor ? glow.radius : 0
        layer.borderWidth = isSelectedColor ? 2 : 1
        layer.borderColor = isSelectedColor ? glow.color.cgColor : NSColor.separatorColor.cgColor
        layer.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: -1, dy: -1), cornerWidth: 6, cornerHeight: 6, transform: nil)
        if animated && isSelectedColor && oldOpacity < newOpacity {
            let animation = CABasicAnimation(keyPath: "shadowOpacity")
            animation.fromValue = oldOpacity
            animation.toValue = newOpacity
            animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "selectedColorGlow")
        }
    }
}

@MainActor
private func positionLegacyColorPanel(_ panel: NSColorPanel, on screen: NSScreen) {
    let visible = screen.visibleFrame
    let size = panel.frame.size
    let centered = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    let origin = CGPoint(
        x: min(max(centered.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
        y: min(max(centered.y, visible.minY), max(visible.minY, visible.maxY - size.height))
    )
    panel.setFrameOrigin(origin)
}

final class ColoredTitleButton: NSButton {
    private let fillColor: NSColor
    private let titleColor: NSColor

    init(title: String, fillColor: NSColor, textColor: NSColor, target: AnyObject?, action: Selector?) {
        self.fillColor = fillColor
        self.titleColor = textColor
        super.init(frame: CGRect(x: 0, y: 0, width: 72, height: 34))
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setContentHuggingPriority(.required, for: .horizontal)
        widthAnchor.constraint(equalToConstant: 72).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        let background = pressed
            ? fillColor.blended(withFraction: 0.22, of: .black) ?? fillColor
            : fillColor
        background.setFill()
        let buttonBounds = pressed ? bounds.insetBy(dx: 1.5, dy: 1.5) : bounds
        NSBezierPath(roundedRect: buttonBounds, xRadius: 8, yRadius: 8).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: titleColor
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        let pressOffset: CGFloat = pressed ? -1 : 0
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 + pressOffset))
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }
}

final class ScreenshotEditorView: NSView, NSTextViewDelegate {
    var mode: ScreenshotAnnotationMode = .arrow
    var showsImageBorder = true
    var pendingText: String?
    var strokeColor: NSColor = .systemRed
    var textColor: NSColor = .white { didSet { updateActiveTextFieldStyle() } }
    var textBackgroundColor: NSColor = .systemBlue { didSet { updateActiveTextFieldStyle() } }
    var textFontSize: CGFloat = 18 { didSet { updateActiveTextFieldStyle() } }
    var onEscape: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onAnnotationDragLocation: ((CGPoint?) -> Void)?
    var onAnnotationDragEnded: ((CGPoint) -> Bool)?
    var onAnnotationAvailabilityChanged: ((Bool) -> Void)?

    private var image: CGImage
    private let imagePadding: CGFloat
    private var annotations: [ScreenshotAnnotation] = [] {
        didSet {
            if oldValue.isEmpty != annotations.isEmpty {
                onAnnotationAvailabilityChanged?(!annotations.isEmpty)
            }
        }
    }
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var movingIndex: Int?
    private var selectedIndex: Int? {
        didSet {
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    private var resizingHandle: AnnotationResizeHandle?
    private var resizeOriginalAnnotation: ScreenshotAnnotation?
    private var lastMovePoint: CGPoint?
    private var activeTextView: NSTextView?
    private var activeTextOrigin: CGPoint?
    private var activeTextAnchor: CGPoint?
    private var suppressNextTextMouseDown = false
    private var activeMosaicPoints: [CGPoint]?
    private var lastMosaicSampleTime: TimeInterval = 0
    private lazy var mosaicImage: CGImage? = makeMosaicImage()

    init(frame: CGRect, image: CGImage, imagePadding: CGFloat = 20) {
        self.image = image
        self.imagePadding = imagePadding
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
        for (handle, point) in controlHandles(for: annotations[selectedIndex]) {
            let viewPoint = viewPoint(from: point)
            let rect = CGRect(x: viewPoint.x - 10, y: viewPoint.y - 10, width: 20, height: 20)
            addCursorRect(rect, cursor: cursor(for: handle))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            onConfirm?()
        } else if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelectedAnnotation()
        } else {
            super.keyDown(with: event)
        }
    }

    func undo() {
        commitActiveText()
        if !annotations.isEmpty {
            annotations.removeLast()
            if annotations.isEmpty {
                selectedIndex = nil
            } else if let selectedIndex {
                self.selectedIndex = min(selectedIndex, annotations.count - 1)
            }
            needsDisplay = true
        }
    }

    func replaceImage(_ newImage: CGImage, annotationOffset: CGPoint) {
        commitActiveText()
        if annotationOffset != .zero {
            for index in annotations.indices {
                moveAnnotation(at: index, by: annotationOffset)
            }
            dragStart = dragStart.map { CGPoint(x: $0.x + annotationOffset.x, y: $0.y + annotationOffset.y) }
            dragEnd = dragEnd.map { CGPoint(x: $0.x + annotationOffset.x, y: $0.y + annotationOffset.y) }
            activeMosaicPoints = activeMosaicPoints?.map {
                CGPoint(x: $0.x + annotationOffset.x, y: $0.y + annotationOffset.y)
            }
        }
        image = newImage
        mosaicImage = makeMosaicImage()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let wasEditingText = activeTextView != nil
        commitActiveText()
        window?.makeFirstResponder(self)
        if suppressNextTextMouseDown {
            suppressNextTextMouseDown = false
            return
        }
        if wasEditingText {
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = imagePoint(from: viewPoint)
        if let index = selectedIndex,
           let handle = hitResizeHandle(at: point, annotation: annotations[index]) {
            resizingHandle = handle
            resizeOriginalAnnotation = annotations[index]
            window?.makeFirstResponder(self)
            return
        }
        if mode != .mosaic, let index = hitAnnotation(point) {
            movingIndex = index
            selectedIndex = index
            lastMovePoint = point
            onAnnotationDragLocation?(nil)
            window?.makeFirstResponder(self)
            return
        }
        selectedIndex = nil
        switch mode {
        case .text:
            beginTextInput(at: point, viewPoint: viewPoint)
        case .arrow, .rectangle, .ellipse:
            dragStart = point
            dragEnd = point
        case .mosaic:
            activeMosaicPoints = [point]
            lastMosaicSampleTime = ProcessInfo.processInfo.systemUptime
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))
        if let index = selectedIndex,
           let handle = resizingHandle,
           let original = resizeOriginalAnnotation {
            resizeAnnotation(at: index, original: original, handle: handle, to: point)
            needsDisplay = true
            return
        }
        if let index = movingIndex, let last = lastMovePoint {
            moveAnnotation(at: index, by: CGPoint(x: point.x - last.x, y: point.y - last.y))
            lastMovePoint = point
            onAnnotationDragLocation?(event.locationInWindow)
            needsDisplay = true
            return
        }
        if activeMosaicPoints != nil {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastMosaicSampleTime >= 0.05 else { return }
            activeMosaicPoints?.append(point)
            lastMosaicSampleTime = now
            needsDisplay = true
            return
        }
        guard dragStart != nil else { return }
        dragEnd = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if resizingHandle != nil {
            resizingHandle = nil
            resizeOriginalAnnotation = nil
            window?.invalidateCursorRects(for: self)
            return
        }
        if let index = movingIndex {
            let shouldDelete = onAnnotationDragEnded?(event.locationInWindow) ?? false
            onAnnotationDragLocation?(nil)
            if shouldDelete {
                removeAnnotation(at: index)
            }
            movingIndex = nil
            lastMovePoint = nil
            window?.invalidateCursorRects(for: self)
            return
        }
        if var points = activeMosaicPoints {
            let end = imagePoint(from: convert(event.locationInWindow, from: nil))
            if points.last.map({ hypot($0.x - end.x, $0.y - end.y) > 1 }) ?? true {
                points.append(end)
            }
            if !points.isEmpty {
                annotations.append(.mosaic(points: points, brushWidth: mosaicBrushWidth))
                selectedIndex = annotations.count - 1
            }
            activeMosaicPoints = nil
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        let end = imagePoint(from: convert(event.locationInWindow, from: nil))
        if hypot(end.x - start.x, end.y - start.y) > 8 {
            switch mode {
            case .arrow:
                annotations.append(.arrow(start: start, end: end, color: strokeColor))
            case .rectangle:
                annotations.append(.rectangle(normalizedRect(start, end), color: strokeColor))
            case .ellipse:
                annotations.append(.ellipse(normalizedRect(start, end), color: strokeColor))
            case .text:
                break
            case .mosaic:
                break
            }
            selectedIndex = annotations.count - 1
        }
        dragStart = nil
        dragEnd = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // A neutral dark workspace keeps the captured image edge visible for
        // both light and dark screenshots.
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        bounds.fill()
        let imageBoundary = NSBezierPath(rect: imageRect)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.set()
        NSColor.black.setFill()
        imageBoundary.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        applyImageTransform(context)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for annotation in annotations { draw(annotation, in: context) }
        if let selectedIndex, annotations.indices.contains(selectedIndex) {
            drawSelectionHandles(for: annotations[selectedIndex], in: context)
        }
        if let points = activeMosaicPoints {
            draw(.mosaic(points: points, brushWidth: mosaicBrushWidth), in: context)
        }
        if let start = dragStart, let end = dragEnd {
            switch mode {
            case .arrow: draw(.arrow(start: start, end: end, color: strokeColor), in: context)
            case .rectangle: draw(.rectangle(normalizedRect(start, end), color: strokeColor), in: context)
            case .ellipse: draw(.ellipse(normalizedRect(start, end), color: strokeColor), in: context)
            case .text: break
            case .mosaic: break
            }
        }
        context.restoreGState()
        if showsImageBorder {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            imageBoundary.lineWidth = 2
            imageBoundary.stroke()
        }
    }

    func renderedImage() -> CGImage? {
        commitActiveText()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for annotation in annotations { draw(annotation, in: context) }
        return context.makeImage()
    }

    fileprivate func applyColorToSelectedAnnotation(_ color: NSColor, target: ColorTarget) {
        guard !annotations.isEmpty else { return }
        let index = selectedIndex.map { min(max($0, 0), annotations.count - 1) } ?? (annotations.count - 1)
        switch (annotations[index], target) {
        case let (.arrow(start, end, _), .stroke):
            annotations[index] = .arrow(start: start, end: end, color: color)
        case let (.rectangle(rect, _), .stroke):
            annotations[index] = .rectangle(rect, color: color)
        case let (.ellipse(rect, _), .stroke):
            annotations[index] = .ellipse(rect, color: color)
        case let (.text(text, origin, fontSize, _, background), .text):
            annotations[index] = .text(text, origin: origin, fontSize: fontSize, textColor: color, backgroundColor: background)
        case let (.text(text, origin, fontSize, textColor, _), .textBackground):
            annotations[index] = .text(text, origin: origin, fontSize: fontSize, textColor: textColor, backgroundColor: color)
        default:
            break
        }
        needsDisplay = true
    }

    private func beginTextInput(at imagePoint: CGPoint, viewPoint: CGPoint) {
        let textView = NSTextView(frame: CGRect(x: viewPoint.x, y: viewPoint.y, width: 20, height: 20))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.drawsBackground = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byClipping
        textView.delegate = self
        textView.wantsLayer = true
        addSubview(textView)
        activeTextView = textView
        activeTextOrigin = imagePoint
        activeTextAnchor = viewPoint
        updateActiveTextFieldStyle()
        window?.makeFirstResponder(textView)
    }

    func textDidEndEditing(_ notification: Notification) {
        if activeTextView != nil {
            suppressNextTextMouseDown = true
        }
        commitActiveText()
    }

    func textDidChange(_ notification: Notification) {
        resizeActiveTextField()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitActiveText()
            window?.makeFirstResponder(self)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            discardActiveText()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    private func resizeActiveTextField() {
        guard let textView = activeTextView, let anchor = activeTextAnchor else { return }
        let font = NSFont.systemFont(ofSize: textFontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]
        let textWidth = ceil(NSAttributedString(string: textView.string, attributes: attributes).size().width)
        let textHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let padding = textFontSize * 0.35
        let width = min(max(padding * 2 + 1, textWidth + padding * 2), max(padding * 2 + 1, bounds.width - anchor.x - 12))
        let height = ceil(textHeight + padding * 2)
        textView.frame = CGRect(x: anchor.x, y: anchor.y - height, width: width, height: height)
        textView.textContainerInset = CGSize(width: padding, height: padding)
    }

    private func updateActiveTextFieldStyle() {
        guard let textView = activeTextView else { return }
        textView.font = .systemFont(ofSize: textFontSize, weight: .semibold)
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.layer?.backgroundColor = textBackgroundColor.withAlphaComponent(0.9).cgColor
        textView.layer?.cornerRadius = textFontSize * 0.35
        resizeActiveTextField()
    }

    private func commitActiveText() {
        guard let textView = activeTextView else { return }
        let text = textView.string
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let origin = activeTextOrigin {
            let imageFontSize = textFontSize * CGFloat(image.width) / imageRect.width
            annotations.append(.text(text, origin: origin, fontSize: imageFontSize, textColor: textColor, backgroundColor: textBackgroundColor))
            selectedIndex = annotations.count - 1
        }
        textView.removeFromSuperview()
        activeTextView = nil
        activeTextOrigin = nil
        activeTextAnchor = nil
        needsDisplay = true
    }

    private func discardActiveText() {
        activeTextView?.removeFromSuperview()
        activeTextView = nil
        activeTextOrigin = nil
        activeTextAnchor = nil
        suppressNextTextMouseDown = false
        needsDisplay = true
    }

    private var imageRect: CGRect {
        let available = bounds.insetBy(dx: imagePadding, dy: imagePadding)
        let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        let rect = imageRect
        let x = min(max((viewPoint.x - rect.minX) / rect.width, 0), 1) * CGFloat(image.width)
        let y = min(max((viewPoint.y - rect.minY) / rect.height, 0), 1) * CGFloat(image.height)
        return CGPoint(x: x, y: y)
    }

    private func applyImageTransform(_ context: CGContext) {
        let rect = imageRect
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / CGFloat(image.width), y: rect.height / CGFloat(image.height))
    }

    private var imageToViewScale: CGFloat {
        imageRect.width / CGFloat(image.width)
    }

    private func viewPoint(from imagePoint: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(
            x: rect.minX + imagePoint.x * rect.width / CGFloat(image.width),
            y: rect.minY + imagePoint.y * rect.height / CGFloat(image.height)
        )
    }

    private func controlHandles(for annotation: ScreenshotAnnotation) -> [(AnnotationResizeHandle, CGPoint)] {
        switch annotation {
        case let .arrow(start, end, _):
            return [(.arrowStart, start), (.arrowEnd, end)]
        case let .rectangle(rect, _), let .ellipse(rect, _):
            return [
                (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
                (.top, CGPoint(x: rect.midX, y: rect.maxY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
                (.right, CGPoint(x: rect.maxX, y: rect.midY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.bottom, CGPoint(x: rect.midX, y: rect.minY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.left, CGPoint(x: rect.minX, y: rect.midY))
            ]
        case .text, .mosaic:
            return []
        }
    }

    private func hitResizeHandle(at point: CGPoint, annotation: ScreenshotAnnotation) -> AnnotationResizeHandle? {
        let tolerance = 11 / max(imageToViewScale, 0.001)
        return controlHandles(for: annotation).first {
            hypot(point.x - $0.1.x, point.y - $0.1.y) <= tolerance
        }?.0
    }

    private func cursor(for handle: AnnotationResizeHandle) -> NSCursor {
        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .arrowStart, .arrowEnd, .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .crosshair
        }
    }

    private func resizeAnnotation(
        at index: Int,
        original: ScreenshotAnnotation,
        handle: AnnotationResizeHandle,
        to point: CGPoint
    ) {
        let clamped = CGPoint(
            x: min(max(point.x, 0), CGFloat(image.width)),
            y: min(max(point.y, 0), CGFloat(image.height))
        )
        switch original {
        case let .arrow(start, end, color):
            if handle == .arrowStart {
                annotations[index] = .arrow(start: clamped, end: end, color: color)
            } else if handle == .arrowEnd {
                annotations[index] = .arrow(start: start, end: clamped, color: color)
            }
        case let .rectangle(rect, color):
            annotations[index] = .rectangle(
                resizedRect(rect, handle: handle, point: clamped),
                color: color
            )
        case let .ellipse(rect, color):
            annotations[index] = .ellipse(
                resizedRect(rect, handle: handle, point: clamped),
                color: color
            )
        case .text, .mosaic:
            break
        }
    }

    private func resizedRect(_ original: CGRect, handle: AnnotationResizeHandle, point: CGPoint) -> CGRect {
        let preferredMinimum = 8 / max(imageToViewScale, 0.001)
        let minimumWidth = min(preferredMinimum, original.width)
        let minimumHeight = min(preferredMinimum, original.height)
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft:
            minX = min(point.x, original.maxX - minimumWidth)
        case .topRight, .right, .bottomRight:
            maxX = max(point.x, original.minX + minimumWidth)
        default:
            break
        }
        switch handle {
        case .topLeft, .top, .topRight:
            maxY = max(point.y, original.minY + minimumHeight)
        case .bottomLeft, .bottom, .bottomRight:
            minY = min(point.y, original.maxY - minimumHeight)
        default:
            break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func drawSelectionHandles(for annotation: ScreenshotAnnotation, in context: CGContext) {
        let handles = controlHandles(for: annotation)
        guard !handles.isEmpty else { return }
        let scale = max(imageToViewScale, 0.001)
        let radius = 5 / scale
        if case let .rectangle(rect, _) = annotation {
            drawSelectionBounds(rect, in: context, scale: scale)
        } else if case let .ellipse(rect, _) = annotation {
            drawSelectionBounds(rect, in: context, scale: scale)
        }
        for (_, point) in handles {
            let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(2 / scale)
            context.strokeEllipse(in: circle.insetBy(dx: 1 / scale, dy: 1 / scale))
        }
    }

    private func drawSelectionBounds(_ rect: CGRect, in context: CGContext, scale: CGFloat) {
        context.saveGState()
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1 / scale)
        context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
        context.stroke(rect)
        context.restoreGState()
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func textRect(_ text: String, at origin: CGPoint, fontSize: CGFloat) -> CGRect {
        let padding = fontSize * 0.35
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]
        let width = NSAttributedString(string: text, attributes: attributes).size().width
        let height = NSLayoutManager().defaultLineHeight(for: font)
        return CGRect(x: origin.x, y: origin.y - height - padding * 2, width: width + padding * 2, height: height + padding * 2)
    }

    private func hitAnnotation(_ point: CGPoint) -> Int? {
        for (index, annotation) in annotations.enumerated().reversed() {
            switch annotation {
            case let .arrow(start, end, _):
                if distance(point, toSegmentFrom: start, to: end) < 22 { return index }
            case let .rectangle(rect, _), let .ellipse(rect, _):
                if rect.insetBy(dx: -12, dy: -12).contains(point) { return index }
            case let .text(text, origin, fontSize, _, _):
                if textRect(text, at: origin, fontSize: fontSize).insetBy(dx: -8, dy: -8).contains(point) { return index }
            case let .mosaic(points, brushWidth):
                if polyline(points, contains: point, tolerance: brushWidth / 2 + 8) { return index }
            }
        }
        return nil
    }

    private func moveAnnotation(at index: Int, by delta: CGPoint) {
        switch annotations[index] {
        case let .arrow(start, end, color):
            annotations[index] = .arrow(start: CGPoint(x: start.x + delta.x, y: start.y + delta.y), end: CGPoint(x: end.x + delta.x, y: end.y + delta.y), color: color)
        case let .rectangle(rect, color):
            annotations[index] = .rectangle(rect.offsetBy(dx: delta.x, dy: delta.y), color: color)
        case let .ellipse(rect, color):
            annotations[index] = .ellipse(rect.offsetBy(dx: delta.x, dy: delta.y), color: color)
        case let .text(text, origin, fontSize, textColor, backgroundColor):
            annotations[index] = .text(text, origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), fontSize: fontSize, textColor: textColor, backgroundColor: backgroundColor)
        case let .mosaic(points, brushWidth):
            annotations[index] = .mosaic(
                points: points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
                brushWidth: brushWidth
            )
        }
    }

    func deleteSelectedAnnotation() {
        guard !annotations.isEmpty else { return }
        let index = selectedIndex.map { min(max($0, 0), annotations.count - 1) } ?? (annotations.count - 1)
        removeAnnotation(at: index)
    }

    private func removeAnnotation(at index: Int) {
        annotations.remove(at: index)
        if annotations.isEmpty {
            selectedIndex = nil
        } else {
            selectedIndex = min(index, annotations.count - 1)
        }
        needsDisplay = true
    }

    private func distance(_ point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if dx == 0 && dy == 0 { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)))
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private var mosaicBrushWidth: CGFloat {
        min(max(CGFloat(image.width) / 18, 36), 96)
    }

    private func polyline(_ points: [CGPoint], contains point: CGPoint, tolerance: CGFloat) -> Bool {
        guard let first = points.first else { return false }
        if points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= tolerance }
        for (start, end) in zip(points, points.dropFirst()) {
            if distance(point, toSegmentFrom: start, to: end) <= tolerance { return true }
        }
        return false
    }

    private func makeMosaicImage() -> CGImage? {
        let blockSize = 16
        let width = max(1, image.width / blockSize)
        let height = max(1, image.height / blockSize)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func drawMosaic(points: [CGPoint], brushWidth: CGFloat, in context: CGContext) {
        guard let mosaicImage, let first = points.first else { return }
        context.saveGState()
        context.beginPath()
        context.move(to: first)
        if points.count == 1 {
            context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
        } else {
            points.dropFirst().forEach { context.addLine(to: $0) }
        }
        context.setLineWidth(brushWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        context.interpolationQuality = .none
        context.draw(mosaicImage, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }

    private func draw(_ annotation: ScreenshotAnnotation, in context: CGContext) {
        switch annotation {
        case let .arrow(start, end, color):
            drawArrow(from: start, to: end, color: color, in: context)
        case let .rectangle(rect, color):
            drawShape(rect, color: color, ellipse: false, in: context)
        case let .ellipse(rect, color):
            drawShape(rect, color: color, ellipse: true, in: context)
        case let .text(text, origin, fontSize, textColor, backgroundColor):
            drawText(text, at: origin, fontSize: fontSize, textColor: textColor, backgroundColor: backgroundColor, in: context)
        case let .mosaic(points, brushWidth):
            drawMosaic(points: points, brushWidth: brushWidth, in: context)
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, color: NSColor, in context: CGContext) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 1 else { return }
        let shaftWidth = min(max(distance * 0.075, 8), 28)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let ux = cos(angle), uy = sin(angle)
        let px = -uy, py = ux

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(shaftWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let arrowStartDistance = max(20, shaftWidth * 2.5)
        guard distance > arrowStartDistance else {
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            context.restoreGState()
            return
        }

        let transitionDistance = max(18, shaftWidth * 2.25)
        let linearProgress = min(max((distance - arrowStartDistance) / transitionDistance, 0), 1)
        let progress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        let fullHeadLength = min(max(distance * 0.24, 18), min(64, distance * 0.45))
        let headLength = fullHeadLength * progress
        let headWidth = shaftWidth + (shaftWidth * 2.8 - shaftWidth) * progress
        let headBase = CGPoint(x: end.x - headLength * ux, y: end.y - headLength * uy)
        let shaftEnd = CGPoint(
            x: end.x - headLength * 0.72 * ux,
            y: end.y - headLength * 0.72 * uy
        )
        context.move(to: start)
        context.addLine(to: shaftEnd)
        context.strokePath()

        let headL = CGPoint(x: headBase.x + px * headWidth / 2, y: headBase.y + py * headWidth / 2)
        let headR = CGPoint(x: headBase.x - px * headWidth / 2, y: headBase.y - py * headWidth / 2)
        context.setFillColor(color.cgColor)
        context.move(to: end)
        context.addLine(to: headL)
        context.addQuadCurve(to: headR, control: headBase)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private func drawShape(_ rect: CGRect, color: NSColor, ellipse: Bool, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(4, CGFloat(image.width) / 220))
        if ellipse {
            context.strokeEllipse(in: rect)
        } else {
            context.stroke(rect)
        }
        context.restoreGState()
    }

    private func drawText(_ text: String, at origin: CGPoint, fontSize: CGFloat, textColor: NSColor, backgroundColor: NSColor, in context: CGContext) {
        let padding = fontSize * 0.35
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let rect = CGRect(x: origin.x, y: origin.y - lineHeight - padding * 2, width: size.width + padding * 2, height: lineHeight + padding * 2)

        context.saveGState()
        context.setFillColor(backgroundColor.withAlphaComponent(0.9).cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: padding, cornerHeight: padding, transform: nil))
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(at: CGPoint(
            x: rect.minX + padding,
            y: rect.minY + padding + (lineHeight - size.height) / 2
        ))
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

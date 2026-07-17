import AppKit
import CoreGraphics

@MainActor
final class DirectAnnotationController: NSObject {
    var onFinish: ((CGImage) -> Void)?
    var onLongCapture: (() -> Void)?
    var onCancel: (() -> Void)?

    private let image: CGImage
    private let selection: CGRect
    private let screen: NSScreen
    private var window: NSWindow?
    private var toolbarWindow: NSWindow?
    private var canvas: ScreenshotEditorView?
    private var mode: ScreenshotAnnotationMode = .arrow
    private var colorTarget: DirectColorTarget = .stroke
    private var arrowButton: ToolButton?
    private var textButton: ToolButton?
    private var rectangleButton: ToolButton?
    private var ellipseButton: ToolButton?
    private var mosaicButton: ToolButton?
    private var textColorButton: NSButton?
    private var textBackgroundButton: NSButton?
    private var deleteDropButton: DeleteDropButton?
    private var finishButton: NSButton?
    private var paletteButtons: [DirectColorButton] = []

    init(image: CGImage, selection: CGRect, screen: NSScreen) {
        self.image = image
        self.selection = selection
        self.screen = screen
    }

    func show() {
        let toolbarHeight: CGFloat = 100
        let canvasView = ScreenshotEditorView(
            frame: CGRect(origin: .zero, size: selection.size),
            image: image,
            imagePadding: 0
        )
        canvasView.autoresizingMask = [.width, .height]
        canvasView.mode = .arrow
        canvasView.showsImageBorder = false
        canvasView.strokeColor = loadColor("annotation.strokeColor", fallback: .systemRed)
        canvasView.textColor = loadColor("annotation.textColor", fallback: .white)
        canvasView.textBackgroundColor = loadColor("annotation.textBackgroundColor", fallback: .systemRed)
        canvasView.onEscape = { [weak self] in self?.cancel() }
        canvas = canvasView

        let window = DirectAnnotationWindow(
            contentRect: CGRect(origin: .zero, size: selection.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.acceptsMouseMovedEvents = true
        window.contentView = canvasView
        window.setFrame(selection, display: false)
        canvasView.onAnnotationDragLocation = { [weak self] point in
            self?.updateDeleteDropTarget(at: point)
        }
        canvasView.onAnnotationDragEnded = { [weak self] point in
            self?.finishDeleteDrop(at: point) ?? false
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvasView)

        let toolbarWidth = min(CGFloat(680), max(CGFloat(320), screen.visibleFrame.width - 24))
        let toolbarFrame = resolvedToolbarFrame(size: CGSize(width: toolbarWidth, height: toolbarHeight))
        let toolbarPanel = NSPanel(
            contentRect: CGRect(origin: .zero, size: toolbarFrame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        toolbarPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbarPanel.isOpaque = false
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.hasShadow = true
        toolbarPanel.acceptsMouseMovedEvents = true
        toolbarPanel.setFrame(toolbarFrame, display: false)
        let toolbar = makeToolbarView(frame: CGRect(origin: .zero, size: toolbarFrame.size))
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 12
        toolbar.layer?.masksToBounds = true
        toolbarPanel.contentView = toolbar
        toolbarPanel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        toolbarWindow = toolbarPanel
        updateToolState()
        toolbar.layoutSubtreeIfNeeded()
        toolbarPanel.orderFrontRegardless()
        if toolbarPanel.alphaValue == 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toolbarPanel.animator().alphaValue = 1
            }
        }
    }

    private func resolvedToolbarFrame(size: CGSize) -> CGRect {
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var x = selection.midX - size.width / 2
        if x < visible.minX {
            x = selection.minX
        } else if x + size.width > visible.maxX {
            x = selection.maxX - size.width
        }
        x = min(max(x, visible.minX), visible.maxX - size.width)

        var y = selection.minY - size.height - 8
        if y < visible.minY {
            y = selection.maxY + 8
        }
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    func close() {
        toolbarWindow?.orderOut(nil)
        toolbarWindow = nil
        window?.orderOut(nil)
        window = nil
        canvas = nil
    }

    private func makeToolbarView(frame: CGRect) -> NSView {
        let content = InstantTooltipToolbarView(frame: frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.spacing = 8
        tools.alignment = .centerY
        tools.translatesAutoresizingMaskIntoConstraints = false

        let delete = DeleteDropButton(target: self, action: #selector(deleteSelectedAnnotation))
        deleteDropButton = delete
        tools.addArrangedSubview(delete)
        tools.addArrangedSubview(button("撤销", action: #selector(undo), toolTip: "撤销上一步"))
        arrowButton = toolButton("arrow.down.right", action: #selector(useArrow), toolTip: "箭头标注")
        textButton = toolButton("textformat", action: #selector(useText), toolTip: "文字标注")
        rectangleButton = toolButton("rectangle", action: #selector(useRectangle), toolTip: "矩形标注")
        ellipseButton = toolButton("circle", action: #selector(useEllipse), toolTip: "椭圆标注")
        mosaicButton = toolButton(image: mosaicToolIcon(), action: #selector(useMosaic), toolTip: "马赛克")
        [arrowButton, textButton, rectangleButton, ellipseButton, mosaicButton].compactMap { $0 }.forEach { tools.addArrangedSubview($0) }
        tools.addArrangedSubview(button("长截图", action: #selector(longCapture), toolTip: "长截图"))
        let finishButton = ColoredTitleButton(title: "完成", fillColor: .systemGreen, textColor: .white, target: self, action: #selector(finish))
        self.finishButton = finishButton
        finishButton.keyEquivalent = "\r"
        finishButton.toolTip = "完成并复制到剪贴板"
        finishButton.translatesAutoresizingMaskIntoConstraints = false

        let palette = NSStackView()
        palette.orientation = .horizontal
        palette.spacing = 8
        palette.alignment = .centerY
        palette.translatesAutoresizingMaskIntoConstraints = false
        let textColor = button("字色", action: #selector(useTextColor))
        let textBackground = button("背景", action: #selector(useTextBackground))
        textColor.wantsLayer = true
        textBackground.wantsLayer = true
        textColor.layer?.cornerRadius = 6
        textBackground.layer?.cornerRadius = 6
        textColorButton = textColor
        textBackgroundButton = textBackground
        palette.addArrangedSubview(textColor)
        palette.addArrangedSubview(textBackground)
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
        for color in colors {
            let swatch = DirectColorButton(color: color, target: self, action: #selector(chooseColor(_:)))
            paletteButtons.append(swatch)
            palette.addArrangedSubview(swatch)
        }

        content.addSubview(tools)
        content.addSubview(palette)
        content.addSubview(finishButton)
        NSLayoutConstraint.activate([
            tools.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            tools.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            finishButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            finishButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            palette.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            palette.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10)
        ])
        content.activateInstantTooltips()
        return content
    }

    private func toolButton(_ symbol: String, action: Selector, toolTip: String) -> ToolButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) ?? NSImage()
        return toolButton(image: image, action: action, toolTip: toolTip)
    }

    private func toolButton(image: NSImage, action: Selector, toolTip: String) -> ToolButton {
        let button = ToolButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = NSColor.controlColor.cgColor
        button.contentTintColor = .labelColor
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.toolTip = toolTip
        return button
    }

    private func button(_ title: String, action: Selector, toolTip: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = toolTip
        return button
    }

    private func mosaicToolIcon() -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            let cells: [(Int, Int, CGFloat)] = [
                (0, 0, 0.45), (1, 0, 1.0), (2, 0, 0.65),
                (0, 1, 1.0), (1, 1, 0.55), (2, 1, 1.0),
                (0, 2, 0.7), (1, 2, 1.0), (2, 2, 0.4)
            ]
            let gap: CGFloat = 1.4
            let cell = (min(rect.width, rect.height) - gap * 2) / 3
            let origin = CGPoint(
                x: rect.midX - (cell * 3 + gap * 2) / 2,
                y: rect.midY - (cell * 3 + gap * 2) / 2
            )
            for (column, row, alpha) in cells {
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: CGRect(
                    x: origin.x + CGFloat(column) * (cell + gap),
                    y: origin.y + CGFloat(row) * (cell + gap),
                    width: cell,
                    height: cell
                ), xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "马赛克"
        return image
    }

    private func updateDeleteDropTarget(at point: CGPoint?) {
        guard let deleteDropButton else { return }
        guard let point, let point = toolbarPoint(fromCanvasWindowPoint: point) else {
            deleteDropButton.isDropTarget = false
            return
        }
        let localPoint = deleteDropButton.convert(point, from: nil)
        deleteDropButton.isDropTarget = deleteDropButton.bounds.contains(localPoint)
    }

    private func finishDeleteDrop(at point: CGPoint) -> Bool {
        guard let deleteDropButton, let point = toolbarPoint(fromCanvasWindowPoint: point) else { return false }
        let localPoint = deleteDropButton.convert(point, from: nil)
        let shouldDelete = deleteDropButton.bounds.contains(localPoint)
        deleteDropButton.isDropTarget = false
        return shouldDelete
    }

    private func toolbarPoint(fromCanvasWindowPoint point: CGPoint) -> CGPoint? {
        guard let window, let toolbarWindow else { return nil }
        return toolbarWindow.convertPoint(fromScreen: window.convertPoint(toScreen: point))
    }

    @objc private func deleteSelectedAnnotation() {
        canvas?.deleteSelectedAnnotation()
        deleteDropButton?.isDropTarget = false
        focusCanvas()
    }

    @objc private func useArrow() {
        mode = .arrow
        colorTarget = .stroke
        canvas?.mode = .arrow
        updateToolState()
        focusCanvas()
    }

    @objc private func useText() {
        mode = .text
        colorTarget = .textBackground
        canvas?.mode = .text
        updateToolState()
        focusCanvas()
    }

    @objc private func useTextColor() {
        mode = .text
        colorTarget = .text
        canvas?.mode = .text
        updateToolState()
        focusCanvas()
    }

    @objc private func useTextBackground() {
        mode = .text
        colorTarget = .textBackground
        canvas?.mode = .text
        updateToolState()
        focusCanvas()
    }

    @objc private func useRectangle() {
        mode = .rectangle
        colorTarget = .stroke
        canvas?.mode = .rectangle
        updateToolState()
        focusCanvas()
    }

    @objc private func useEllipse() {
        mode = .ellipse
        colorTarget = .stroke
        canvas?.mode = .ellipse
        updateToolState()
        focusCanvas()
    }

    @objc private func useMosaic() {
        mode = .mosaic
        canvas?.mode = .mosaic
        updateToolState()
        focusCanvas()
    }

    @objc private func chooseColor(_ sender: DirectColorButton) {
        guard let canvas else { return }
        switch colorTarget {
        case .stroke:
            canvas.strokeColor = sender.color
            saveColor(sender.color, key: "annotation.strokeColor")
        case .text:
            canvas.textColor = sender.color
            saveColor(sender.color, key: "annotation.textColor")
        case .textBackground:
            canvas.textBackgroundColor = sender.color
            saveColor(sender.color, key: "annotation.textBackgroundColor")
        }
        updateToolState()
        focusCanvas()
    }

    @objc private func undo() {
        canvas?.undo()
        focusCanvas()
    }

    @objc private func longCapture() {
        onLongCapture?()
    }

    @objc private func finish() {
        guard let image = canvas?.renderedImage() else { return }
        onFinish?(image)
    }

    private func cancel() {
        onCancel?()
    }

    private func updateToolState() {
        let stroke = canvas?.strokeColor ?? .systemRed
        arrowButton?.configure(top: nil, bottom: stroke, selected: mode == .arrow)
        rectangleButton?.configure(top: nil, bottom: stroke, selected: mode == .rectangle)
        ellipseButton?.configure(top: nil, bottom: stroke, selected: mode == .ellipse)
        mosaicButton?.configure(top: nil, bottom: nil, selected: mode == .mosaic)
        textButton?.configure(top: canvas?.textColor ?? .white, bottom: canvas?.textBackgroundColor ?? .systemRed, selected: mode == .text)
        textColorButton?.isHidden = mode != .text
        textBackgroundButton?.isHidden = mode != .text
        updateColorTargetButton(textColorButton, selected: colorTarget == .text)
        updateColorTargetButton(textBackgroundButton, selected: colorTarget == .textBackground)
        let active = currentColor()
        paletteButtons.forEach { $0.isSelectedColor = colorsMatch($0.color, active) }
    }

    private func updateColorTargetButton(_ button: NSButton?, selected: Bool) {
        guard let button else { return }
        button.state = selected ? .on : .off
        button.contentTintColor = selected ? .systemBlue : .labelColor
        button.layer?.borderWidth = selected ? 2 : 0
        button.layer?.borderColor = selected ? NSColor.systemBlue.cgColor : NSColor.clear.cgColor
        button.layer?.backgroundColor = selected
            ? NSColor.systemBlue.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
    }

    private func focusCanvas() {
        guard let canvas else { return }
        window?.makeKey()
        window?.makeFirstResponder(canvas)
    }


    private func currentColor() -> NSColor {
        guard let canvas else { return .systemRed }
        switch colorTarget {
        case .stroke: return canvas.strokeColor
        case .text: return canvas.textColor
        case .textBackground: return canvas.textBackgroundColor
        }
    }

    private func saveColor(_ color: NSColor, key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func loadColor(_ key: String, fallback: NSColor) -> NSColor {
        guard let data = UserDefaults.standard.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return fallback
        }
        return color
    }

    private func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.deviceRGB),
              let b = rhs.usingColorSpace(.deviceRGB) else { return lhs == rhs }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
            && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }
}

private final class DirectPreviewBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
    }
}

private final class DirectAnnotationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class InstantTooltipToolbarView: NSView {
    private var tracking: NSTrackingArea?
    private var tooltipText: [ObjectIdentifier: String] = [:]
    private weak var currentTarget: NSView?
    private weak var pendingTarget: NSView?
    private var tooltipWorkItem: DispatchWorkItem?
    private let tooltipLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.cell = VerticallyCenteredTextFieldCell(textCell: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        label.layer?.cornerRadius = 5
        label.isHidden = true
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(tooltipLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func activateInstantTooltips() {
        collectTooltips(from: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let target = tooltipTarget(at: point) else {
            hideTooltip()
            return
        }
        scheduleTooltip(for: target)
    }

    override func mouseExited(with event: NSEvent) {
        hideTooltip()
    }

    private func collectTooltips(from view: NSView) {
        for subview in view.subviews where subview !== tooltipLabel {
            if let text = subview.toolTip, !text.isEmpty {
                tooltipText[ObjectIdentifier(subview)] = text
                subview.toolTip = nil
            }
            collectTooltips(from: subview)
        }
    }

    private func tooltipTarget(at point: CGPoint) -> NSView? {
        var candidate = hitTest(point)
        while let view = candidate, view !== self {
            if tooltipText[ObjectIdentifier(view)] != nil { return view }
            candidate = view.superview
        }
        return nil
    }

    private func showTooltip(for target: NSView) {
        guard currentTarget !== target, let text = tooltipText[ObjectIdentifier(target)] else { return }
        currentTarget = target
        tooltipLabel.stringValue = text
        tooltipLabel.sizeToFit()
        var frame = tooltipLabel.frame.insetBy(dx: -8, dy: -4)
        let targetFrame = target.convert(target.bounds, to: self)
        frame.origin.x = min(max(targetFrame.midX - frame.width / 2, 4), bounds.maxX - frame.width - 4)
        let aboveTarget = targetFrame.maxY + 6
        frame.origin.y = aboveTarget + frame.height <= bounds.maxY - 4
            ? aboveTarget
            : max(4, targetFrame.minY - frame.height - 6)
        tooltipLabel.frame = frame
        tooltipLabel.alphaValue = 1
        tooltipLabel.isHidden = false
        addSubview(tooltipLabel, positioned: .above, relativeTo: nil)
    }

    private func scheduleTooltip(for target: NSView) {
        guard currentTarget !== target, pendingTarget !== target else { return }
        tooltipWorkItem?.cancel()
        tooltipLabel.isHidden = true
        currentTarget = nil
        pendingTarget = target
        let workItem = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target, self.pendingTarget === target else { return }
            self.pendingTarget = nil
            self.showTooltip(for: target)
        }
        tooltipWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func hideTooltip() {
        tooltipWorkItem?.cancel()
        tooltipWorkItem = nil
        pendingTarget = nil
        currentTarget = nil
        tooltipLabel.isHidden = true
        tooltipLabel.alphaValue = 0
    }
}

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = ceil(max(attributedStringValue.size().height, font?.boundingRectForFont.height ?? 0))
        guard textHeight > 0, drawingRect.height > textHeight else { return drawingRect }
        drawingRect.origin.y += floor((drawingRect.height - textHeight) / 2)
        drawingRect.size.height = textHeight
        return drawingRect
    }
}

private final class DeleteDropButton: NSButton {
    var isDropTarget = false { didSet { updateAppearance() } }

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        self.target = target
        self.action = action
        image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除标注")
        imageScaling = .scaleProportionallyDown
        bezelStyle = .texturedRounded
        wantsLayer = true
        layer?.cornerRadius = 7
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        toolTip = "拖动标注到这里删除"
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAppearance() {
        layer?.backgroundColor = (isDropTarget ? NSColor.systemRed : NSColor.controlColor).cgColor
        contentTintColor = isDropTarget ? .white : .labelColor
        layer?.borderWidth = isDropTarget ? 2 : 0
        layer?.borderColor = isDropTarget ? NSColor.white.withAlphaComponent(0.9).cgColor : NSColor.clear.cgColor
    }
}

extension DirectAnnotationController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }
}

private enum DirectColorTarget {
    case stroke
    case text
    case textBackground
}


private final class ToolButton: NSButton {
    private var topColor: NSColor?
    private var bottomColor: NSColor?

    func configure(top: NSColor?, bottom: NSColor?, selected: Bool) {
        topColor = top
        bottomColor = bottom
        wantsLayer = true
        let glow = DirectGlowStyle.current
        layer?.masksToBounds = false
        layer?.shadowColor = glow.color.cgColor
        layer?.shadowOpacity = selected ? glow.opacity : 0
        layer?.shadowRadius = selected ? glow.radius : 0
        layer?.shadowOffset = .zero
        layer?.borderWidth = selected ? 2 : 0
        layer?.borderColor = selected ? glow.color.cgColor : NSColor.clear.cgColor
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: -1, dy: -1), cornerWidth: 8, cornerHeight: 8, transform: nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBar(color: topColor, y: bounds.minY + 4)
        drawBar(color: bottomColor, y: bounds.maxY - 6)
    }

    private func drawBar(color: NSColor?, y: CGFloat) {
        guard let color else { return }
        let width = min(22, max(16, bounds.width - 12))
        let rect = CGRect(x: (bounds.width - width) / 2, y: y, width: width, height: 2)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }
}

private final class DirectColorButton: NSButton {
    let color: NSColor
    var isSelectedColor = false { didSet { updateGlow() } }

    init(color: NSColor, target: AnyObject?, action: Selector?) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = color.cgColor
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    private func updateGlow() {
        let glow = DirectGlowStyle.current
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = glow.color.cgColor
        layer?.shadowOpacity = isSelectedColor ? glow.opacity : 0
        layer?.shadowRadius = isSelectedColor ? glow.radius : 0
        layer?.shadowOffset = .zero
        layer?.borderWidth = isSelectedColor ? 2 : 1
        layer?.borderColor = isSelectedColor ? glow.color.cgColor : NSColor.separatorColor.cgColor
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: -1, dy: -1), cornerWidth: 6, cornerHeight: 6, transform: nil)
    }
}

@MainActor
private struct DirectGlowStyle {
    let color: NSColor
    let opacity: Float
    let radius: CGFloat

    static var current: DirectGlowStyle {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if appearance == .aqua {
            return DirectGlowStyle(color: NSColor(calibratedRed: 0.0, green: 0.42, blue: 1.0, alpha: 1), opacity: 1.0, radius: 4)
        } else {
            return DirectGlowStyle(color: .systemBlue, opacity: 1.0, radius: 4)
        }
    }
}

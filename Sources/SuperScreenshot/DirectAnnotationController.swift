import AppKit
import CoreGraphics

@MainActor
final class DirectAnnotationController: NSObject {
    var onFinish: ((CGImage) -> Void)?
    var onLongCapture: ((CGRect) -> Void)?
    var onScreenRecording: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onSelectionChanged: ((CGRect) -> Void)?

    private let initialImage: CGImage
    private let fullScreenImage: CGImage?
    private var selection: CGRect
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
    private var fontSizeLabel: NSTextField?
    private var fontSizeSlider: NSSlider?
    private var deleteDropButton: DeleteDropButton?
    private var finishButton: NSButton?
    private var paletteButtons: [DirectColorButton] = []
    private var customColorButton: DirectCustomColorButton?
    private weak var activeColorPanel: NSColorPanel?
    private var colorPanelClickMonitor: Any?
    private var resizeWindows: [SelectionResizeHandle: NSPanel] = [:]
    private var resizeStartSelection: CGRect?
    private var resizeCursorMonitor: Any?
    private var isShowingResizeCursor = false

    init(image: CGImage, selection: CGRect, screen: NSScreen, fullScreenImage: CGImage? = nil) {
        self.fullScreenImage = fullScreenImage
        self.selection = selection
        self.screen = screen
        self.initialImage = image
    }

    func show() {
        let toolbarHeight: CGFloat = 100
        let canvasView = ScreenshotEditorView(
            frame: CGRect(origin: .zero, size: selection.size),
            image: initialImage,
            imagePadding: 0
        )
        canvasView.autoresizingMask = [.width, .height]
        canvasView.mode = .arrow
        canvasView.showsImageBorder = false
        canvasView.strokeColor = loadColor("annotation.strokeColor", fallback: .systemRed)
        canvasView.textColor = loadColor("annotation.textColor", fallback: .white)
        canvasView.textBackgroundColor = loadColor("annotation.textBackgroundColor", fallback: .systemRed)
        let savedFontSize = UserDefaults.standard.double(forKey: "annotation.textFontSize")
        canvasView.textFontSize = savedFontSize > 0 ? CGFloat(savedFontSize) : 18
        canvasView.onEscape = { [weak self] in self?.cancel() }
        canvasView.onConfirm = { [weak self] in self?.finish() }
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
        canvasView.onAnnotationAvailabilityChanged = { [weak self] hasAnnotations in
            self?.deleteDropButton?.isHidden = !hasAnnotations
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
        toolbar.layoutSubtreeIfNeeded()
        updateToolState()
        toolbarPanel.orderFrontRegardless()
        if toolbarPanel.alphaValue == 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toolbarPanel.animator().alphaValue = 1
            }
        }
        installResizeHandles()
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

    private func installResizeHandles() {
        guard fullScreenImage != nil else { return }
        for handle in SelectionResizeHandle.allCases {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.sharingType = .none
            panel.acceptsMouseMovedEvents = true
            let view = SelectionResizeHandleView(handle: handle)
            view.onDragBegan = { [weak self] in self?.resizeStartSelection = self?.selection }
            view.onDrag = { [weak self] point in self?.resizeSelection(handle: handle, to: point) }
            view.onDragEnded = { [weak self] in
                self?.resizeStartSelection = nil
                self?.focusCanvas()
            }
            panel.contentView = view
            resizeWindows[handle] = panel
            panel.orderFrontRegardless()
        }
        updateResizeHandleFrames()
        installResizeCursorMonitor()
    }

    private func installResizeCursorMonitor() {
        resizeCursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateResizeCursor(at: NSEvent.mouseLocation)
            return event
        }
    }

    private func updateResizeCursor(at point: CGPoint) {
        if toolbarWindow?.frame.contains(point) == true || activeColorPanel?.frame.contains(point) == true {
            if isShowingResizeCursor {
                isShowingResizeCursor = false
                DispatchQueue.main.async { NSCursor.arrow.set() }
            }
            return
        }
        if let handle = resizeHandle(at: point) {
            isShowingResizeCursor = true
            let cursor = SelectionResizeCursor.cursor(for: handle)
            DispatchQueue.main.async { cursor.set() }
        } else if isShowingResizeCursor {
            isShowingResizeCursor = false
            DispatchQueue.main.async { NSCursor.arrow.set() }
        }
    }

    private func resizeHandle(at point: CGPoint) -> SelectionResizeHandle? {
        let tolerance: CGFloat = 20
        let nearLeft = abs(point.x - selection.minX) <= tolerance
        let nearRight = abs(point.x - selection.maxX) <= tolerance
        let nearBottom = abs(point.y - selection.minY) <= tolerance
        let nearTop = abs(point.y - selection.maxY) <= tolerance
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && point.y >= selection.minY && point.y <= selection.maxY { return .left }
        if nearRight && point.y >= selection.minY && point.y <= selection.maxY { return .right }
        if nearBottom && point.x >= selection.minX && point.x <= selection.maxX { return .bottom }
        if nearTop && point.x >= selection.minX && point.x <= selection.maxX { return .top }
        return nil
    }

    private func resizeSelection(handle: SelectionResizeHandle, to point: CGPoint) {
        guard let start = resizeStartSelection else { return }
        let limits = screen.frame
        let minimum: CGFloat = 40
        var next = start
        if handle.movesLeft {
            let x = min(max(point.x, limits.minX), start.maxX - minimum)
            next.origin.x = x
            next.size.width = start.maxX - x
        }
        if handle.movesRight {
            next.size.width = max(min(point.x, limits.maxX), start.minX + minimum) - start.minX
        }
        if handle.movesBottom {
            let y = min(max(point.y, limits.minY), start.maxY - minimum)
            next.origin.y = y
            next.size.height = start.maxY - y
        }
        if handle.movesTop {
            next.size.height = max(min(point.y, limits.maxY), start.minY + minimum) - start.minY
        }
        next = ScreenCapture.pixelAligned(next, scale: screen.backingScaleFactor)
        applySelection(next)
    }

    private func applySelection(_ next: CGRect) {
        guard next != selection, let fullScreenImage,
              let cropped = ScreenCapture.crop(fullScreenImage, to: next, on: screen),
              let canvas else { return }
        let old = selection
        let scaleX = CGFloat(fullScreenImage.width) / screen.frame.width
        let scaleY = CGFloat(fullScreenImage.height) / screen.frame.height
        let offset = CGPoint(
            x: (old.minX - next.minX) * scaleX,
            y: (old.minY - next.minY) * scaleY
        )
        selection = next
        window?.setFrame(next, display: true)
        canvas.replaceImage(cropped, annotationOffset: offset)
        if let toolbarWindow {
            toolbarWindow.setFrame(resolvedToolbarFrame(size: toolbarWindow.frame.size), display: true)
        }
        updateResizeHandleFrames()
        onSelectionChanged?(next)
    }

    private func updateResizeHandleFrames() {
        let edge: CGFloat = 40
        let corner: CGFloat = 40
        for (handle, panel) in resizeWindows {
            let frame: CGRect
            switch handle {
            case .left:
                frame = CGRect(x: selection.minX - edge / 2, y: selection.minY + corner / 2,
                               width: edge, height: max(edge, selection.height - corner))
            case .right:
                frame = CGRect(x: selection.maxX - edge / 2, y: selection.minY + corner / 2,
                               width: edge, height: max(edge, selection.height - corner))
            case .bottom:
                frame = CGRect(x: selection.minX + corner / 2, y: selection.minY - edge / 2,
                               width: max(edge, selection.width - corner), height: edge)
            case .top:
                frame = CGRect(x: selection.minX + corner / 2, y: selection.maxY - edge / 2,
                               width: max(edge, selection.width - corner), height: edge)
            case .bottomLeft:
                frame = CGRect(x: selection.minX - corner / 2, y: selection.minY - corner / 2,
                               width: corner, height: corner)
            case .bottomRight:
                frame = CGRect(x: selection.maxX - corner / 2, y: selection.minY - corner / 2,
                               width: corner, height: corner)
            case .topLeft:
                frame = CGRect(x: selection.minX - corner / 2, y: selection.maxY - corner / 2,
                               width: corner, height: corner)
            case .topRight:
                frame = CGRect(x: selection.maxX - corner / 2, y: selection.maxY - corner / 2,
                               width: corner, height: corner)
            }
            panel.setFrame(frame, display: true)
            if let contentView = panel.contentView {
                panel.invalidateCursorRects(for: contentView)
            }
        }
    }

    func close() {
        if let resizeCursorMonitor {
            NSEvent.removeMonitor(resizeCursorMonitor)
            self.resizeCursorMonitor = nil
        }
        if isShowingResizeCursor {
            NSCursor.arrow.set()
            isShowingResizeCursor = false
        }
        resizeWindows.values.forEach { $0.orderOut(nil) }
        resizeWindows.removeAll()
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
        delete.isHidden = true
        deleteDropButton = delete
        tools.addArrangedSubview(delete)
        tools.addArrangedSubview(button(L("撤销"), action: #selector(undo), toolTip: L("撤销上一步")))
        arrowButton = toolButton("arrow.down.right", action: #selector(useArrow), toolTip: L("箭头标注"))
        textButton = toolButton(image: textAnnotationIcon(), action: #selector(useText), toolTip: L("文字标注"))
        rectangleButton = toolButton("rectangle", action: #selector(useRectangle), toolTip: L("矩形标注"))
        ellipseButton = toolButton("circle", action: #selector(useEllipse), toolTip: L("椭圆标注"))
        mosaicButton = toolButton(image: mosaicToolIcon(), action: #selector(useMosaic), toolTip: L("马赛克"))
        [arrowButton, textButton, rectangleButton, ellipseButton, mosaicButton].compactMap { $0 }.forEach { tools.addArrangedSubview($0) }
        tools.addArrangedSubview(button(L("长截图"), action: #selector(longCapture), toolTip: L("长截图")))
        tools.addArrangedSubview(button(L("录屏"), action: #selector(screenRecording), toolTip: L("录制当前区域")))
        let finishButton = ColoredTitleButton(title: L("完成"), fillColor: .systemGreen, textColor: .white, target: self, action: #selector(finish))
        self.finishButton = finishButton
        finishButton.keyEquivalent = "\r"
        finishButton.toolTip = L("完成并复制到剪贴板")
        finishButton.translatesAutoresizingMaskIntoConstraints = false

        let palette = NSStackView()
        palette.orientation = .horizontal
        palette.spacing = 8
        palette.alignment = .centerY
        palette.translatesAutoresizingMaskIntoConstraints = false
        let textColor = button(L("字色"), action: #selector(useTextColor))
        let textBackground = button(L("背景"), action: #selector(useTextBackground))
        let sizeLabel = NSTextField(labelWithString: L("字号"))
        let sizeSlider = NSSlider(
            value: Double(canvas?.textFontSize ?? 18),
            minValue: 12,
            maxValue: 48,
            target: self,
            action: #selector(changeTextFontSize(_:))
        )
        sizeSlider.isContinuous = true
        sizeSlider.widthAnchor.constraint(equalToConstant: 92).isActive = true
        textColor.wantsLayer = true
        textBackground.wantsLayer = true
        textColor.layer?.cornerRadius = 6
        textBackground.layer?.cornerRadius = 6
        textColorButton = textColor
        textBackgroundButton = textBackground
        fontSizeLabel = sizeLabel
        fontSizeSlider = sizeSlider
        palette.addArrangedSubview(sizeLabel)
        palette.addArrangedSubview(sizeSlider)
        palette.addArrangedSubview(textColor)
        palette.addArrangedSubview(textBackground)
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
        for color in colors {
            let swatch = DirectColorButton(color: color, target: self, action: #selector(chooseColor(_:)))
            paletteButtons.append(swatch)
            palette.addArrangedSubview(swatch)
        }
        let customColor = DirectCustomColorButton(target: self, action: #selector(showCustomColorPanel))
        customColorButton = customColor
        palette.addArrangedSubview(customColor)

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
        image.accessibilityDescription = L("马赛克")
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

    @objc private func changeTextFontSize(_ sender: NSSlider) {
        let size = CGFloat(sender.doubleValue.rounded())
        canvas?.textFontSize = size
        UserDefaults.standard.set(Double(size), forKey: "annotation.textFontSize")
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
        applyColor(sender.color)
    }

    @objc private func showCustomColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.color = currentColor()
        if let window {
            panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        }
        positionColorPanel(panel, beside: toolbarWindow?.frame, on: screen)
        activeColorPanel = panel
        installColorPanelClickMonitor(for: panel)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        applyColor(sender.color)
    }

    private func applyColor(_ color: NSColor) {
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
        updateToolState()
        focusCanvas()
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

    @objc private func undo() {
        canvas?.undo()
        focusCanvas()
    }

    @objc private func longCapture() {
        onLongCapture?(selection)
    }

    @objc private func screenRecording() {
        onScreenRecording?(selection)
    }

    @objc private func finish() {
        guard let image = canvas?.renderedImage() else { return }
        closeColorPanel()
        onFinish?(image)
    }

    private func cancel() {
        closeColorPanel()
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
        fontSizeLabel?.isHidden = mode != .text
        fontSizeSlider?.isHidden = mode != .text
        updateColorTargetButton(textColorButton, selected: colorTarget == .text)
        updateColorTargetButton(textBackgroundButton, selected: colorTarget == .textBackground)
        let active = currentColor()
        paletteButtons.forEach { $0.isSelectedColor = colorsMatch($0.color, active) }
        customColorButton?.isSelectedColor = !paletteButtons.contains { colorsMatch($0.color, active) }
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

@MainActor
private func positionColorPanel(_ panel: NSColorPanel, beside toolbarFrame: CGRect?, on screen: NSScreen) {
    let visible = screen.visibleFrame
    let size = panel.frame.size
    let spacing: CGFloat = 10
    let toolbar = toolbarFrame ?? CGRect(x: visible.midX, y: visible.midY, width: 0, height: 0)
    let rightX = toolbar.maxX + spacing
    let leftX = toolbar.minX - spacing - size.width
    let preferredX: CGFloat
    if rightX + size.width <= visible.maxX {
        preferredX = rightX
    } else if leftX >= visible.minX {
        preferredX = leftX
    } else {
        preferredX = rightX
    }
    let preferredY = toolbar.midY - size.height / 2
    let origin = CGPoint(
        x: min(max(preferredX, visible.minX), max(visible.minX, visible.maxX - size.width)),
        y: min(max(preferredY, visible.minY), max(visible.minY, visible.maxY - size.height))
    )
    panel.setFrameOrigin(origin)
}

private enum SelectionResizeHandle: CaseIterable {
    case left, right, bottom, top
    case bottomLeft, bottomRight, topLeft, topRight

    var movesLeft: Bool { self == .left || self == .bottomLeft || self == .topLeft }
    var movesRight: Bool { self == .right || self == .bottomRight || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var isHorizontalEdge: Bool { self == .left || self == .right }
    var isVerticalEdge: Bool { self == .top || self == .bottom }
}

private final class SelectionResizeHandleView: NSView {
    let handle: SelectionResizeHandle
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    init(handle: SelectionResizeHandle) {
        self.handle = handle
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private var resizeCursor: NSCursor {
        SelectionResizeCursor.cursor(for: handle)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseEntered(with event: NSEvent) { resizeCursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        onDrag?(NSEvent.mouseLocation)
        onDragEnded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // A nearly transparent surface makes the full resize band participate in
        // mouse and cursor hit testing instead of only the visible center knob.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill(using: .copy)
        let size: CGFloat = 8
        let knob = CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor.systemBlue.setStroke()
        let outline = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 2
        outline.stroke()
    }
}

@MainActor
private enum SelectionResizeCursor {
    static let diagonalRising = makeCursor(rising: true)
    static let diagonalFalling = makeCursor(rising: false)

    static func cursor(for handle: SelectionResizeHandle) -> NSCursor {
        if handle.isHorizontalEdge {
            return .resizeLeftRight
        } else if handle.isVerticalEdge {
            return .resizeUpDown
        } else if handle == .bottomLeft || handle == .topRight {
            return diagonalRising
        } else {
            return diagonalFalling
        }
    }

    private static func makeCursor(rising: Bool) -> NSCursor {
        let image = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { rect in
            let start = rising ? CGPoint(x: 3, y: 3) : CGPoint(x: 3, y: 17)
            let end = rising ? CGPoint(x: 17, y: 17) : CGPoint(x: 17, y: 3)
            let direction = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let length = hypot(direction.x, direction.y)
            let unit = CGPoint(x: direction.x / length, y: direction.y / length)
            let perpendicular = CGPoint(x: -unit.y, y: unit.x)
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            for (tip, sign) in [(start, CGFloat(1)), (end, CGFloat(-1))] {
                let base = CGPoint(x: tip.x + unit.x * 5 * sign, y: tip.y + unit.y * 5 * sign)
                path.move(to: tip)
                path.line(to: CGPoint(x: base.x + perpendicular.x * 3, y: base.y + perpendicular.y * 3))
                path.move(to: tip)
                path.line(to: CGPoint(x: base.x - perpendicular.x * 3, y: base.y - perpendicular.y * 3))
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 4
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 2
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 10, y: 10))
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
        image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("删除标注"))
        imageScaling = .scaleProportionallyDown
        bezelStyle = .texturedRounded
        wantsLayer = true
        layer?.cornerRadius = 7
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        toolTip = L("拖动标注到这里删除")
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
        closeColorPanel()
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
        updateShadowPath()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    private func updateShadowPath() {
        guard !bounds.isEmpty else { return }
        layer?.shadowPath = CGPath(
            roundedRect: bounds.insetBy(dx: -1, dy: -1),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
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

private final class DirectCustomColorButton: NSButton {
    var isSelectedColor = false { didSet { needsDisplay = true } }

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.masksToBounds = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [.systemRed, .systemYellow, .systemGreen, .systemCyan, .systemBlue, .systemPurple, .systemRed])?
            .draw(in: rect, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        let glow = DirectGlowStyle.current
        (isSelectedColor ? glow.color : NSColor.separatorColor).setStroke()
        path.lineWidth = isSelectedColor ? 2 : 1
        path.stroke()

        NSColor.white.setStroke()
        let plus = NSBezierPath()
        plus.lineWidth = 2
        plus.move(to: CGPoint(x: bounds.midX - 4, y: bounds.midY))
        plus.line(to: CGPoint(x: bounds.midX + 4, y: bounds.midY))
        plus.move(to: CGPoint(x: bounds.midX, y: bounds.midY - 4))
        plus.line(to: CGPoint(x: bounds.midX, y: bounds.midY + 4))
        plus.stroke()

        layer?.shadowColor = glow.color.cgColor
        layer?.shadowOpacity = isSelectedColor ? glow.opacity : 0
        layer?.shadowRadius = isSelectedColor ? glow.radius : 0
        layer?.shadowOffset = .zero
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

import AppKit

enum SharedAnnotationColorTarget {
    case stroke
    case text
    case textBackground
}

/// The single annotation-toolbar implementation used by screenshot and recording editors.
@MainActor
final class SharedAnnotationToolbar: InstantTooltipToolbarView {
    var onDelete: (() -> Void)?
    var onUndo: (() -> Void)?
    var onMode: ((ScreenshotAnnotationMode) -> Void)?
    var onColorTarget: ((SharedAnnotationColorTarget) -> Void)?
    var onFontSize: ((CGFloat) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onCustomColor: (() -> Void)?
    var onLongCapture: (() -> Void)?
    var onScreenRecording: (() -> Void)?
    var onFinish: (() -> Void)?

    let deleteDropButton: DeleteDropButton
    private let undoButton: NSButton
    private let arrowButton: ToolButton
    private let textButton: ToolButton
    private let rectangleButton: ToolButton
    private let ellipseButton: ToolButton
    private let mosaicButton: ToolButton
    private let textColorButton: NSButton
    private let textBackgroundButton: NSButton
    private let fontSizeLabel: NSTextField
    private let fontSizeSlider: NSSlider
    private let paletteButtons: [DirectColorButton]
    private let customColorButton: DirectCustomColorButton
    let finishButton: NSButton?

    init(frame: CGRect, showsCaptureActions: Bool, showsFinish: Bool) {
        deleteDropButton = DeleteDropButton(target: nil, action: nil)
        undoButton = NSButton(title: L("撤销"), target: nil, action: nil)
        arrowButton = SharedAnnotationToolbar.toolButton("arrow.down.right", tooltip: L("箭头标注"))
        textButton = SharedAnnotationToolbar.toolButton(image: SharedAnnotationToolbar.textIcon(), tooltip: L("文字标注"))
        rectangleButton = SharedAnnotationToolbar.toolButton("rectangle", tooltip: L("矩形标注"))
        ellipseButton = SharedAnnotationToolbar.toolButton("circle", tooltip: L("椭圆标注"))
        mosaicButton = SharedAnnotationToolbar.toolButton(image: SharedAnnotationToolbar.mosaicIcon(), tooltip: L("马赛克"))
        textColorButton = NSButton(title: L("字色"), target: nil, action: nil)
        textBackgroundButton = NSButton(title: L("背景"), target: nil, action: nil)
        fontSizeLabel = NSTextField(labelWithString: L("字号"))
        fontSizeSlider = NSSlider(value: 18, minValue: 12, maxValue: 48, target: nil, action: nil)
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
        paletteButtons = colors.map { DirectColorButton(color: $0, target: nil, action: nil) }
        customColorButton = DirectCustomColorButton(target: nil, action: nil)
        finishButton = showsFinish ? ColoredTitleButton(title: L("完成"), fillColor: .systemGreen, textColor: .white, target: nil, action: nil) : nil
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        deleteDropButton.target = self
        deleteDropButton.action = #selector(deleteSelected)
        deleteDropButton.isHidden = true
        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.bezelStyle = .rounded
        arrowButton.target = self; arrowButton.action = #selector(selectMode(_:)); arrowButton.tag = ScreenshotAnnotationMode.arrow.rawValue
        textButton.target = self; textButton.action = #selector(selectMode(_:)); textButton.tag = ScreenshotAnnotationMode.text.rawValue
        rectangleButton.target = self; rectangleButton.action = #selector(selectMode(_:)); rectangleButton.tag = ScreenshotAnnotationMode.rectangle.rawValue
        ellipseButton.target = self; ellipseButton.action = #selector(selectMode(_:)); ellipseButton.tag = ScreenshotAnnotationMode.ellipse.rawValue
        mosaicButton.target = self; mosaicButton.action = #selector(selectMode(_:)); mosaicButton.tag = ScreenshotAnnotationMode.mosaic.rawValue
        textColorButton.target = self; textColorButton.action = #selector(selectTextColor)
        textBackgroundButton.target = self; textBackgroundButton.action = #selector(selectTextBackground)
        [textColorButton, textBackgroundButton].forEach { $0.bezelStyle = .rounded; $0.wantsLayer = true; $0.layer?.cornerRadius = 6 }
        fontSizeSlider.target = self; fontSizeSlider.action = #selector(changeFontSize(_:)); fontSizeSlider.isContinuous = true
        fontSizeSlider.widthAnchor.constraint(equalToConstant: 92).isActive = true
        for button in paletteButtons { button.target = self; button.action = #selector(selectColor(_:)) }
        customColorButton.target = self; customColorButton.action = #selector(selectCustomColor)
        if let finishButton {
            finishButton.target = self; finishButton.action = #selector(finish)
            finishButton.keyEquivalent = "\r"
            finishButton.toolTip = L("完成并复制到剪贴板")
            finishButton.translatesAutoresizingMaskIntoConstraints = false
        }

        let tools = NSStackView()
        tools.orientation = .horizontal; tools.spacing = 8; tools.alignment = .centerY; tools.translatesAutoresizingMaskIntoConstraints = false
        [deleteDropButton, undoButton, arrowButton, textButton, rectangleButton, ellipseButton, mosaicButton].forEach { tools.addArrangedSubview($0) }
        if showsCaptureActions {
            let long = NSButton(title: L("长截图"), target: self, action: #selector(longCapture)); long.bezelStyle = .rounded; long.toolTip = L("长截图")
            let recording = NSButton(title: L("录屏"), target: self, action: #selector(screenRecording)); recording.bezelStyle = .rounded; recording.toolTip = L("录制当前区域")
            tools.addArrangedSubview(long); tools.addArrangedSubview(recording)
        }

        let palette = NSStackView()
        palette.orientation = .horizontal; palette.spacing = 8; palette.alignment = .centerY; palette.translatesAutoresizingMaskIntoConstraints = false
        palette.addArrangedSubview(fontSizeLabel); palette.addArrangedSubview(fontSizeSlider)
        palette.addArrangedSubview(textColorButton); palette.addArrangedSubview(textBackgroundButton)
        paletteButtons.forEach { palette.addArrangedSubview($0) }
        palette.addArrangedSubview(customColorButton)

        addSubview(tools); addSubview(palette)
        if let finishButton { addSubview(finishButton) }
        NSLayoutConstraint.activate([
            tools.centerXAnchor.constraint(equalTo: centerXAnchor),
            tools.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            palette.centerXAnchor.constraint(equalTo: centerXAnchor),
            palette.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10)
        ])
        if let finishButton {
            NSLayoutConstraint.activate([
                finishButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                finishButton.topAnchor.constraint(equalTo: topAnchor, constant: 10)
            ])
        }
        activateInstantTooltips()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(canvas: ScreenshotEditorView?, mode: ScreenshotAnnotationMode, colorTarget: SharedAnnotationColorTarget, hasAnnotations: Bool) {
        let stroke = canvas?.strokeColor ?? .systemRed
        arrowButton.configure(top: nil, bottom: stroke, selected: mode == .arrow)
        rectangleButton.configure(top: nil, bottom: stroke, selected: mode == .rectangle)
        ellipseButton.configure(top: nil, bottom: stroke, selected: mode == .ellipse)
        mosaicButton.configure(top: nil, bottom: nil, selected: mode == .mosaic)
        textButton.configure(top: canvas?.textColor ?? .white, bottom: canvas?.textBackgroundColor ?? .systemRed, selected: mode == .text)
        let textMode = mode == .text
        textColorButton.isHidden = !textMode; textBackgroundButton.isHidden = !textMode
        fontSizeLabel.isHidden = !textMode; fontSizeSlider.isHidden = !textMode
        fontSizeSlider.doubleValue = Double(canvas?.textFontSize ?? 18)
        updateTarget(textColorButton, selected: colorTarget == .text)
        updateTarget(textBackgroundButton, selected: colorTarget == .textBackground)
        let selectedColor: NSColor
        switch colorTarget { case .stroke: selectedColor = stroke; case .text: selectedColor = canvas?.textColor ?? .white; case .textBackground: selectedColor = canvas?.textBackgroundColor ?? .systemRed }
        paletteButtons.forEach { $0.isSelectedColor = SharedAnnotationToolbar.colorsMatch($0.color, selectedColor) }
        customColorButton.isSelectedColor = !paletteButtons.contains { SharedAnnotationToolbar.colorsMatch($0.color, selectedColor) }
        undoButton.isEnabled = hasAnnotations
        deleteDropButton.isHidden = !hasAnnotations
    }

    @objc private func deleteSelected() { onDelete?() }
    @objc private func undo() { onUndo?() }
    @objc private func selectMode(_ sender: NSButton) { onMode?(ScreenshotAnnotationMode(rawValue: sender.tag) ?? .arrow) }
    @objc private func selectTextColor() { onColorTarget?(.text) }
    @objc private func selectTextBackground() { onColorTarget?(.textBackground) }
    @objc private func changeFontSize(_ sender: NSSlider) { onFontSize?(CGFloat(sender.doubleValue.rounded())) }
    @objc private func selectColor(_ sender: DirectColorButton) { onColor?(sender.color) }
    @objc private func selectCustomColor() { onCustomColor?() }
    @objc private func longCapture() { onLongCapture?() }
    @objc private func screenRecording() { onScreenRecording?() }
    @objc private func finish() { onFinish?() }

    private func updateTarget(_ button: NSButton, selected: Bool) {
        button.state = selected ? .on : .off
        button.contentTintColor = selected ? .systemBlue : .labelColor
        button.layer?.borderWidth = selected ? 2 : 0
        button.layer?.borderColor = selected ? NSColor.systemBlue.cgColor : NSColor.clear.cgColor
        button.layer?.backgroundColor = selected ? NSColor.systemBlue.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
    }

    private static func toolButton(_ symbol: String, tooltip: String) -> ToolButton {
        toolButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(), tooltip: tooltip)
    }
    private static func toolButton(image: NSImage, tooltip: String) -> ToolButton {
        let button = ToolButton(image: image, target: nil, action: nil)
        button.bezelStyle = .texturedRounded; button.imageScaling = .scaleProportionallyDown
        button.wantsLayer = true; button.layer?.cornerRadius = 7; button.layer?.backgroundColor = NSColor.controlColor.cgColor
        button.contentTintColor = .labelColor; button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true; button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }
    private static func textIcon() -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            let text = NSAttributedString(string: "T", attributes: attributes)
            let size = text.size()
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 1))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L("文字标注")
        return image
    }
    private static func mosaicIcon() -> NSImage { NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: L("马赛克")) ?? NSImage() }
    private static func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.deviceRGB), let b = rhs.usingColorSpace(.deviceRGB) else { return lhs == rhs }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01 && abs(a.blueComponent - b.blueComponent) < 0.01 && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }
}

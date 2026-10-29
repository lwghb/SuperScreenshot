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
    var onBrushWidth: ((CGFloat) -> Void)?
    var onFontSize: ((CGFloat) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onCustomColor: (() -> Void)?
    var onLongCapture: (() -> Void)?
    var onRecordingSettingsEnter: (() -> Void)?
    var onRecordingSettingsExit: (() -> Void)?
    var onRecordingSettings: (() -> Void)?
    var onScreenRecording: (() -> Void)?
    var onFinish: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    static let collapsedWidth: CGFloat = 348
    static let collapsedHeight: CGFloat = 48
    static let expandedHeight: CGFloat = 100
    private(set) var isExpanded = false
    var parameterContentView: NSView { optionsContent }
    var displayedHeight: CGFloat { toolbarHeightConstraint.constant }
    private var toolbarWidthConstraint: NSLayoutConstraint?
    private var toolbarHeightConstraint: NSLayoutConstraint!
    private var expansionTask: Task<Void, Never>?
    private var currentMode: ScreenshotAnnotationMode = .arrow
    private let palette = NSStackView()
    private let toolsHoverView = AnnotationToolsHoverView()
    private let toolChoices = NSStackView()
    private let actionStrip = NSStackView()
    private let actionsBackground = NSView()
    private let mainBackground = NSView()
    private var actionsInsetConstraint: NSLayoutConstraint!
    private let optionsPopover = NSPopover()
    private let optionsContent = AnnotationToolsHoverView()
    private let pickerContent = AnnotationToolsHoverView()
    private var pickerPanel: NSPanel?
    private var pickerAnimationTask: Task<Void, Never>?
    private var overPicker = false
    var toolPickerContentView: NSView { pickerContent }
    private var inlineCenterConstraint: NSLayoutConstraint?
    private var settingsHoverTask: Task<Void, Never>?
    private var hoverExpandTask: Task<Void, Never>?
    private var overTools = false
    private var overOptions = false
    private var recentToolButton: ToolButton!
    private var toolsWidthConstraint: NSLayoutConstraint!
    private(set) var isToolPickerExpanded = false
    private var hasAnnotations = false
    private let showsCaptureActions: Bool
    private var displayedWidth: CGFloat = SharedAnnotationToolbar.collapsedWidth
    private(set) var recordingSettingsAnchor: NSView?
    private var suppressHoverUntilExit = false
    private var hoverExitTask: Task<Void, Never>?

    let deleteDropButton: DeleteDropButton
    private let undoButton: NSButton
    private let arrowButton: ToolButton
    private let textButton: ToolButton
    private let rectangleButton: ToolButton
    private let ellipseButton: ToolButton
    private let brushButton: ToolButton
    private let brushWidthLabel = NSTextField(labelWithString: L("粗细"))
    private let brushWidthSlider = NSSlider(value: 4, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let mosaicButton: ToolButton
    private let textColorButton: NSButton
    private let textBackgroundButton: NSButton
    private let fontSizeLabel: NSTextField
    private let fontSizeSlider: NSSlider
    private let paletteButtons: [DirectColorButton]
    private let customColorButton: DirectCustomColorButton
    let finishButton: NSButton?

    init(frame: CGRect, showsCaptureActions: Bool, showsFinish: Bool) {
        self.showsCaptureActions = showsCaptureActions
        deleteDropButton = DeleteDropButton(target: nil, action: nil)
        undoButton = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: L("撤销")) ?? NSImage(), target: nil, action: nil)
        arrowButton = SharedAnnotationToolbar.toolButton("arrow.down.right", tooltip: L("箭头标注"))
        textButton = SharedAnnotationToolbar.toolButton(image: SharedAnnotationToolbar.textIcon(), tooltip: L("文字标注"))
        rectangleButton = SharedAnnotationToolbar.toolButton("rectangle", tooltip: L("矩形标注"))
        ellipseButton = SharedAnnotationToolbar.toolButton("circle", tooltip: L("椭圆标注"))
        brushButton = SharedAnnotationToolbar.toolButton("pencil.tip", tooltip: L("自由画笔"))
        mosaicButton = SharedAnnotationToolbar.toolButton(image: SharedAnnotationToolbar.mosaicIcon(), tooltip: L("马赛克"))
        textColorButton = NSButton(title: L("字色"), target: nil, action: nil)
        textBackgroundButton = NSButton(title: L("背景"), target: nil, action: nil)
        fontSizeLabel = NSTextField(labelWithString: L("字号"))
        fontSizeSlider = NSSlider(value: 18, minValue: 12, maxValue: 48, target: nil, action: nil)
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
        paletteButtons = colors.map { DirectColorButton(color: $0, target: nil, action: nil) }
        customColorButton = DirectCustomColorButton(target: nil, action: nil)
        finishButton = showsFinish ? AnnotationActionButton(title: L("完成"), target: nil, action: nil) : nil
        (finishButton as? AnnotationActionButton)?.fillColor = NSColor(calibratedRed: 0.15, green: 0.51, blue: 0.29, alpha: 1)
        (finishButton as? AnnotationActionButton)?.titleColor = .white
        var compactFrame = frame
        compactFrame.size.height = Self.collapsedHeight
        if showsCaptureActions { compactFrame.size.width = Self.collapsedWidth }
        super.init(frame: compactFrame)
        toolbarHeightConstraint = heightAnchor.constraint(equalToConstant: Self.collapsedHeight)
        toolbarHeightConstraint.isActive = true
        if showsCaptureActions {
            toolbarWidthConstraint = widthAnchor.constraint(equalToConstant: compactFrame.width)
            toolbarWidthConstraint?.isActive = true
        }

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        mainBackground.translatesAutoresizingMaskIntoConstraints = false
        mainBackground.wantsLayer = true
        mainBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        mainBackground.layer?.cornerRadius = 12
        mainBackground.layer?.borderWidth = 1
        mainBackground.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        addSubview(mainBackground)
        actionsInsetConstraint = mainBackground.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            actionsInsetConstraint,
            mainBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            mainBackground.heightAnchor.constraint(equalToConstant: Self.collapsedHeight)
        ])

        deleteDropButton.target = self
        deleteDropButton.action = #selector(deleteSelected)
        deleteDropButton.isHidden = true
        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.title = ""
        undoButton.imagePosition = .imageOnly
        undoButton.bezelStyle = .texturedRounded
        undoButton.identifier = NSUserInterfaceItemIdentifier("annotation.undo")
        undoButton.toolTip = L("撤销")
        undoButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        undoButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        arrowButton.target = self; arrowButton.action = #selector(selectMode(_:)); arrowButton.tag = ScreenshotAnnotationMode.arrow.rawValue
        textButton.target = self; textButton.action = #selector(selectMode(_:)); textButton.tag = ScreenshotAnnotationMode.text.rawValue
        rectangleButton.target = self; rectangleButton.action = #selector(selectMode(_:)); rectangleButton.tag = ScreenshotAnnotationMode.rectangle.rawValue
        ellipseButton.target = self; ellipseButton.action = #selector(selectMode(_:)); ellipseButton.tag = ScreenshotAnnotationMode.ellipse.rawValue
        mosaicButton.target = self; mosaicButton.action = #selector(selectMode(_:)); mosaicButton.tag = ScreenshotAnnotationMode.mosaic.rawValue
        brushButton.target = self; brushButton.action = #selector(selectMode(_:)); brushButton.tag = ScreenshotAnnotationMode.brush.rawValue
        brushWidthSlider.target = self; brushWidthSlider.action = #selector(changeBrushWidth(_:))
        brushWidthSlider.isContinuous = true
        brushWidthSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        brushWidthSlider.toolTip = L("粗细")
        textColorButton.target = self; textColorButton.action = #selector(selectTextColor)
        textBackgroundButton.target = self; textBackgroundButton.action = #selector(selectTextBackground)
        [textColorButton, textBackgroundButton].forEach { $0.bezelStyle = .rounded; $0.wantsLayer = true; $0.layer?.cornerRadius = 6 }
        fontSizeSlider.target = self; fontSizeSlider.action = #selector(changeFontSize(_:)); fontSizeSlider.isContinuous = true
        fontSizeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
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
        actionStrip.orientation = .horizontal; actionStrip.spacing = 6; actionStrip.alignment = .centerY
        actionStrip.addArrangedSubview(deleteDropButton); actionStrip.addArrangedSubview(undoButton)
        actionStrip.isHidden = true
        actionStrip.identifier = NSUserInterfaceItemIdentifier("annotation.actions")

        recentToolButton = SharedAnnotationToolbar.toolButton("arrow.down.right", tooltip: L("标注工具"))
        recentToolButton.identifier = NSUserInterfaceItemIdentifier("annotation.recent")
        recentToolButton.target = self; recentToolButton.action = #selector(selectRecentTool)
        recentToolButton.translatesAutoresizingMaskIntoConstraints = false
        toolChoices.orientation = .vertical; toolChoices.spacing = 6; toolChoices.alignment = .centerX
        toolChoices.translatesAutoresizingMaskIntoConstraints = false
        [arrowButton, textButton, rectangleButton, ellipseButton, brushButton, mosaicButton].forEach { button in
            button.title = button.toolTip ?? ""
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.constraints.first { $0.firstAttribute == .width }?.constant = 144
            toolChoices.addArrangedSubview(button)
        }
        toolChoices.identifier = NSUserInterfaceItemIdentifier("annotation.choices")
        toolChoices.isHidden = true; toolChoices.alphaValue = 0
        toolsHoverView.wantsLayer = true
        toolsHoverView.layer?.masksToBounds = true
        toolsHoverView.addSubview(recentToolButton)
        pickerContent.wantsLayer = true
        pickerContent.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        pickerContent.layer?.cornerRadius = 12
        pickerContent.layer?.borderWidth = 1
        pickerContent.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        pickerContent.layer?.masksToBounds = true
        pickerContent.addSubview(toolChoices)
        pickerContent.onEnter = { [weak self] in
            self?.overPicker = true
            self?.hoverExitTask?.cancel()
        }
        pickerContent.onExit = { [weak self] in
            self?.overPicker = false
            self?.scheduleHoverClose()
        }
        toolsHoverView.identifier = NSUserInterfaceItemIdentifier("annotation.hover")
        toolsHoverView.translatesAutoresizingMaskIntoConstraints = false
        toolsWidthConstraint = toolsHoverView.widthAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            toolsWidthConstraint,
            toolsHoverView.heightAnchor.constraint(equalToConstant: Self.collapsedHeight),
            recentToolButton.centerXAnchor.constraint(equalTo: toolsHoverView.centerXAnchor),
            recentToolButton.centerYAnchor.constraint(equalTo: toolsHoverView.centerYAnchor),
            toolChoices.centerXAnchor.constraint(equalTo: pickerContent.centerXAnchor),
            toolChoices.topAnchor.constraint(equalTo: pickerContent.topAnchor, constant: 8)
        ])
        toolsHoverView.onEnter = { [weak self] in self?.beginToolHover() }
        toolsHoverView.onExit = { [weak self] in
            guard let self else { return }
            self.overTools = false
            if self.pickerPanel == nil { self.suppressHoverUntilExit = false }
            self.hoverExpandTask?.cancel()
            self.scheduleHoverClose()
        }
        recentToolButton.onRightClick = { [weak self] in
            self?.hoverExpandTask?.cancel()
            self?.setToolPickerExpanded(true)
        }
        optionsContent.onEnter = { [weak self] in
            self?.overOptions = true
            self?.hoverExitTask?.cancel()
            self?.hoverExpandTask?.cancel()
        }
        optionsContent.onExit = { [weak self] in
            self?.overOptions = false
            self?.scheduleHoverClose()
        }

        if showsCaptureActions {
            let recordingGroup = NSView()
            recordingGroup.translatesAutoresizingMaskIntoConstraints = false
            let recording = AnnotationActionButton(title: L("录屏"), target: self, action: #selector(screenRecording))
            recording.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: L("录屏"))
            recording.toolTip = L("录制当前区域")
            recording.identifier = NSUserInterfaceItemIdentifier("recording.start")
            recording.translatesAutoresizingMaskIntoConstraints = false
            let settings = AnnotationSettingsHoverButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("录屏设置")) ?? NSImage(), target: self, action: #selector(recordingSettings))
            let settingsColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65)
            settings.image = settings.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [settingsColor])))
            settings.onEnter = { [weak self] in
                guard let self else { return }
                self.onRecordingSettingsEnter?()
                self.settingsHoverTask?.cancel()
                self.settingsHoverTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                    self?.recordingSettings()
                }
            }
            settings.onExit = { [weak self] in
                self?.settingsHoverTask?.cancel()
                self?.onRecordingSettingsExit?()
            }
            settings.identifier = NSUserInterfaceItemIdentifier("recording.settings")
            settings.bezelStyle = .regularSquare
            settings.isBordered = false; settings.contentTintColor = settingsColor
            settings.toolTip = L("录屏设置")
            settings.translatesAutoresizingMaskIntoConstraints = false
            recordingGroup.addSubview(recording); recordingGroup.addSubview(settings)
            recordingSettingsAnchor = settings
            let long = AnnotationActionButton(title: L("长截图"), target: self, action: #selector(longCapture))
            long.image = NSImage(systemSymbolName: "rectangle.expand.vertical", accessibilityDescription: L("长截图"))
            long.toolTip = L("长截图")
            long.identifier = NSUserInterfaceItemIdentifier("capture.scrolling")
            tools.addArrangedSubview(recordingGroup)
            tools.addArrangedSubview(toolsHoverView)
            tools.addArrangedSubview(long)
            NSLayoutConstraint.activate([
                recordingGroup.widthAnchor.constraint(equalToConstant: 100),
                recordingGroup.heightAnchor.constraint(equalToConstant: Self.collapsedHeight),
                recording.leadingAnchor.constraint(equalTo: recordingGroup.leadingAnchor),
                recording.trailingAnchor.constraint(equalTo: recordingGroup.trailingAnchor),
                recording.topAnchor.constraint(equalTo: recordingGroup.topAnchor),
                recording.bottomAnchor.constraint(equalTo: recordingGroup.bottomAnchor),
                settings.leadingAnchor.constraint(equalTo: recordingGroup.leadingAnchor, constant: 2),
                settings.bottomAnchor.constraint(equalTo: recordingGroup.bottomAnchor, constant: -2),
                settings.widthAnchor.constraint(equalToConstant: 22),
                settings.heightAnchor.constraint(equalToConstant: 22),
                long.widthAnchor.constraint(equalTo: recordingGroup.widthAnchor),
                long.heightAnchor.constraint(equalToConstant: Self.collapsedHeight)
            ])
            if #unavailable(macOS 13.0) { recording.isEnabled = false; settings.isEnabled = false }
        } else {
            tools.addArrangedSubview(toolsHoverView)
        }
        if let finishButton {
            tools.addArrangedSubview(finishButton)
            finishButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
            finishButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }

        palette.orientation = .horizontal; palette.spacing = 6; palette.alignment = .centerY; palette.translatesAutoresizingMaskIntoConstraints = false
        palette.addArrangedSubview(brushWidthLabel); palette.addArrangedSubview(brushWidthSlider)
        palette.addArrangedSubview(fontSizeLabel); palette.addArrangedSubview(fontSizeSlider)
        palette.addArrangedSubview(textColorButton); palette.addArrangedSubview(textBackgroundButton)
        paletteButtons.forEach { palette.addArrangedSubview($0) }
        palette.addArrangedSubview(customColorButton)

        actionsBackground.translatesAutoresizingMaskIntoConstraints = false
        actionsBackground.wantsLayer = true
        actionsBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        actionsBackground.layer?.cornerRadius = 12
        actionsBackground.layer?.borderWidth = 1
        actionsBackground.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        actionsBackground.isHidden = true
        actionsBackground.addSubview(actionStrip)
        actionStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionsBackground)
        addSubview(tools)
        NSLayoutConstraint.activate([
            actionsBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionsBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionsBackground.heightAnchor.constraint(equalToConstant: Self.collapsedHeight),
            actionsBackground.widthAnchor.constraint(equalTo: actionStrip.widthAnchor, constant: 12),
            actionStrip.centerXAnchor.constraint(equalTo: actionsBackground.centerXAnchor),
            actionStrip.centerYAnchor.constraint(equalTo: actionsBackground.centerYAnchor)
        ])
        optionsContent.addSubview(palette)
        optionsContent.frame = CGRect(x: 0, y: 0, width: 340, height: 48)
        NSLayoutConstraint.activate([
            palette.centerXAnchor.constraint(equalTo: optionsContent.centerXAnchor),
            palette.centerYAnchor.constraint(equalTo: optionsContent.centerYAnchor),
            tools.bottomAnchor.constraint(equalTo: bottomAnchor),
            tools.heightAnchor.constraint(equalToConstant: Self.collapsedHeight)
        ])
        let optionsController = NSViewController()
        optionsController.view = optionsContent
        optionsPopover.contentViewController = optionsController
        optionsPopover.behavior = .applicationDefined
        optionsPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if showsCaptureActions {
            NSLayoutConstraint.activate([
                tools.leadingAnchor.constraint(equalTo: mainBackground.leadingAnchor, constant: 8),
                tools.trailingAnchor.constraint(equalTo: mainBackground.trailingAnchor, constant: -8)
            ])
        } else {
            inlineCenterConstraint = tools.centerXAnchor.constraint(equalTo: centerXAnchor)
            inlineCenterConstraint?.isActive = true
        }
        palette.isHidden = true
        palette.alphaValue = 0
        palette.identifier = NSUserInterfaceItemIdentifier("annotation.options")
        activateInstantTooltips()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(canvas: ScreenshotEditorView?, mode: ScreenshotAnnotationMode, colorTarget: SharedAnnotationColorTarget, hasAnnotations: Bool) {
        currentMode = mode
        let stroke = canvas?.strokeColor ?? .systemRed
        arrowButton.configure(top: nil, bottom: stroke, selected: mode == .arrow)
        rectangleButton.configure(top: nil, bottom: stroke, selected: mode == .rectangle)
        ellipseButton.configure(top: nil, bottom: stroke, selected: mode == .ellipse)
        brushButton.configure(top: nil, bottom: stroke, selected: mode == .brush)
        brushWidthLabel.isHidden = mode != .brush; brushWidthSlider.isHidden = mode != .brush
        brushWidthSlider.doubleValue = Double(canvas?.brushWidth ?? 4)
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
        undoButton.isHidden = !hasAnnotations
        deleteDropButton.isHidden = !hasAnnotations
        actionStrip.isHidden = !hasAnnotations
        actionsBackground.isHidden = !hasAnnotations
        let selectedTool: ToolButton
        switch mode {
        case .arrow: selectedTool = arrowButton
        case .text: selectedTool = textButton
        case .rectangle: selectedTool = rectangleButton
        case .ellipse: selectedTool = ellipseButton
        case .brush: selectedTool = brushButton
        case .mosaic: selectedTool = mosaicButton
        }
        recentToolButton.image = selectedTool.image
        recentToolButton.tag = mode.rawValue
        recentToolButton.configure(top: mode == .text ? canvas?.textColor ?? .white : nil,
                                   bottom: mode == .mosaic ? nil : (mode == .text ? canvas?.textBackgroundColor ?? .systemRed : stroke), selected: true)
        if isExpanded { updateOptionsPopover() }
        if self.hasAnnotations != hasAnnotations {
            self.hasAnnotations = hasAnnotations
            animateLayout(animated: true)
        }
    }

    @objc private func deleteSelected() { onDelete?() }
    @objc private func undo() { onUndo?() }
    @objc private func selectMode(_ sender: NSButton) {
        let mode = ScreenshotAnnotationMode(rawValue: sender.tag) ?? .arrow
        hoverExitTask?.cancel()
        hoverExpandTask?.cancel()
        suppressHoverUntilExit = true
        setExpanded(false)
        onMode?(mode)
        setToolPickerExpanded(false)
    }

    @objc private func selectRecentTool() {
        setToolPickerExpanded(!isToolPickerExpanded)
    }

    func setToolPickerExpanded(_ expanded: Bool, animated: Bool = true) {
        dismissInstantTooltip()
        hoverExpandTask?.cancel()
        hoverExitTask?.cancel()
        if expanded {
            overOptions = false
            setExpanded(false)
        }
        guard isToolPickerExpanded != expanded else {
            if !expanded && !animated {
                pickerAnimationTask?.cancel()
                if let panel = pickerPanel { panel.parent?.removeChildWindow(panel) }
                pickerPanel?.orderOut(nil)
                pickerPanel = nil
                toolChoices.isHidden = true
                overPicker = false
            }
            return
        }
        isToolPickerExpanded = expanded
        pickerAnimationTask?.cancel()
        if expanded, pickerPanel == nil {
            guard let window else { isToolPickerExpanded = false; return }
            let anchor = window.convertToScreen(recentToolButton.convert(recentToolButton.bounds, to: nil))
            let visible = window.screen?.visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
            let size = CGSize(width: 160, height: 238)
            let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            let y = anchor.maxY + 8
            let frame = CGRect(x: x, y: min(max(y, visible.minY + 8), visible.maxY - size.height - 8), width: size.width, height: size.height)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = window.level; panel.hidesOnDeactivate = false
            panel.contentView = pickerContent
            pickerPanel = panel
            toolChoices.isHidden = false; toolChoices.alphaValue = 1
            pickerContent.layoutSubtreeIfNeeded()
            panel.setFrame(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 1), display: false)
            panel.alphaValue = 0
            window.addChildWindow(panel, ordered: .above)
        }
        guard let panel = pickerPanel else { return }
        let startFrame = panel.frame
        let startAlpha = panel.alphaValue
        let targetHeight: CGFloat = expanded ? 238 : 1
        let render = { (progress: CGFloat) in
            panel.setFrame(CGRect(x: startFrame.minX, y: startFrame.minY, width: startFrame.width,
                                  height: startFrame.height + (targetHeight - startFrame.height) * progress), display: true)
            panel.alphaValue = startAlpha + ((expanded ? 1 : 0) - startAlpha) * progress
        }
        let finish = { [weak self] in
            guard let self, !self.isToolPickerExpanded else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.pickerPanel = nil
            self.toolChoices.isHidden = true
            self.overPicker = false
            // Resizing/removing the child panel can synthesize tracking events.
            // Do not let those events reopen parameters under a stationary pointer.
            if let window = self.window {
                let toolFrame = window.convertToScreen(self.toolsHoverView.convert(self.toolsHoverView.bounds, to: nil))
                self.overTools = toolFrame.contains(NSEvent.mouseLocation)
                self.suppressHoverUntilExit = self.overTools
            }
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            render(1); finish(); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        pickerAnimationTask = Task { @MainActor in
            while !Task.isCancelled {
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.22)
                render(CGFloat(progress * progress * (3 - 2 * progress)))
                if progress >= 1 { finish(); return }
                do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
            }
        }
    }

    private func beginToolHover() {
        overTools = true
        hoverExitTask?.cancel()
        hoverExpandTask?.cancel()
        guard !suppressHoverUntilExit, pickerPanel == nil else { return }
        hoverExpandTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, self.overTools, !self.suppressHoverUntilExit, self.pickerPanel == nil else { return }
            self.setExpanded(true)
        }
    }
    private func scheduleHoverClose() {
        hoverExitTask?.cancel()
        hoverExitTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard let self, !self.overTools, !self.overOptions, !self.overPicker else { return }
            self.setToolPickerExpanded(false)
            self.setExpanded(false)
        }
    }
    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard !expanded || (pickerPanel == nil && !suppressHoverUntilExit) else { return }
        isExpanded = expanded
        palette.isHidden = !expanded
        palette.alphaValue = expanded ? 1 : 0
        if expanded { updateOptionsPopover() }
        else { optionsPopover.performClose(nil) }
    }
    private func updateOptionsPopover() {
        let width: CGFloat = currentMode == .text ? 560 : (currentMode == .brush ? 450 : 330)
        optionsPopover.contentSize = CGSize(width: width, height: 48)
        guard window?.isVisible == true else { return }
        if !optionsPopover.isShown {
            optionsPopover.show(relativeTo: recentToolButton.convert(recentToolButton.bounds, to: toolsHoverView), of: toolsHoverView, preferredEdge: .minY)
        }
    }
    func closeTransientUI() {
        dismissInstantTooltip()
        settingsHoverTask?.cancel()
        hoverExpandTask?.cancel(); hoverExitTask?.cancel(); expansionTask?.cancel()
        overTools = false; overOptions = false
        suppressHoverUntilExit = false
        setToolPickerExpanded(false, animated: false)
        animateLayout(animated: false)
        setExpanded(false)
    }
    private func screenCenter(of view: NSView) -> CGPoint? {
        guard let window else { return nil }
        return window.convertPoint(toScreen: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    }

    private func animateLayout(animated: Bool, anchoredAt anchor: CGPoint? = nil) {
        expansionTask?.cancel()
        let anchorTarget = recentToolButton!
        let stableAnchor = anchor ?? screenCenter(of: recentToolButton)
        let startInset = actionsInsetConstraint.constant
        let targetInset: CGFloat = hasAnnotations ? 94 : 0
        let startHeight = displayedHeight
        let startWidth = displayedWidth
        let startToolWidth = toolsWidthConstraint.constant
        let startPaletteAlpha = palette.alphaValue
        let targetHeight = Self.collapsedHeight
        let targetToolWidth: CGFloat = 44
        let rowWidth = Self.collapsedWidth + (hasAnnotations ? 94 : 0)
        let targetWidth = rowWidth
        let targetPaletteAlpha: CGFloat = isExpanded ? 1 : 0
        let finish = { [weak self] in
            guard let self else { return }
            self.palette.isHidden = !self.isExpanded
        }
        let render = { [weak self] (progress: CGFloat) in
            guard let self else { return }
            self.actionsInsetConstraint.constant = startInset + (targetInset - startInset) * progress
            self.toolsWidthConstraint.constant = startToolWidth + (targetToolWidth - startToolWidth) * progress
            self.palette.alphaValue = startPaletteAlpha + (targetPaletteAlpha - startPaletteAlpha) * progress
            self.applyGeometry(height: startHeight + (targetHeight - startHeight) * progress,
                               width: startWidth + (targetWidth - startWidth) * progress)
            if let stableAnchor, let current = self.screenCenter(of: anchorTarget), let window = self.window {
                let delta = stableAnchor.x - current.x
                if window.contentView === self {
                    var frame = window.frame.offsetBy(dx: delta, dy: 0)
                    if let visible = window.screen?.visibleFrame {
                        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
                    }
                    window.setFrame(frame, display: true)
                } else if let center = self.inlineCenterConstraint {
                    center.constant += delta
                    self.layoutSubtreeIfNeeded()
                }
            }
            if self.optionsPopover.isShown {
                self.optionsPopover.positioningRect = anchorTarget.convert(anchorTarget.bounds, to: self.toolsHoverView)
            }
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window != nil else {
            render(1); finish(); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        expansionTask = Task { @MainActor in
            while !Task.isCancelled {
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.22)
                render(CGFloat(progress * progress * (3 - 2 * progress)))
                if progress >= 1 { finish(); return }
                do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
            }
        }
    }

    private func applyGeometry(height: CGFloat, width: CGFloat) {
        toolbarHeightConstraint.constant = height
        toolbarWidthConstraint?.constant = width
        displayedWidth = width
        if let onHeightChange {
            onHeightChange(height)
        } else if let window, window.contentView === self {
            var frame = window.frame
            frame.origin.x += (frame.width - width) / 2
            frame.size = CGSize(width: width, height: height)
            if let visible = window.screen?.visibleFrame {
                frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - width - 8)
                frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - height - 8)
            }
            window.setFrame(frame, display: true)
        } else {
            setFrameSize(CGSize(width: frame.width, height: height))
        }
        layoutSubtreeIfNeeded()
    }
    @objc private func selectTextColor() { onColorTarget?(.text) }
    @objc private func selectTextBackground() { onColorTarget?(.textBackground) }
    @objc private func changeBrushWidth(_ sender: NSSlider) { onBrushWidth?(CGFloat(sender.doubleValue.rounded())) }
    @objc private func changeFontSize(_ sender: NSSlider) { onFontSize?(CGFloat(sender.doubleValue.rounded())) }
    @objc private func selectColor(_ sender: DirectColorButton) { onColor?(sender.color) }
    @objc private func selectCustomColor() { onCustomColor?() }
    @objc private func longCapture() { closeTransientUI(); onLongCapture?() }
    @objc private func recordingSettings() { closeTransientUI(); onRecordingSettings?() }
    @objc private func screenRecording() { closeTransientUI(); onScreenRecording?() }
    @objc private func finish() { closeTransientUI(); onFinish?() }

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
        button.usesCompactStyle = true
        button.bezelStyle = .texturedRounded; button.imageScaling = .scaleProportionallyDown
        button.wantsLayer = true; button.layer?.cornerRadius = 7; button.layer?.backgroundColor = NSColor.controlColor.cgColor
        button.contentTintColor = .labelColor; button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true; button.heightAnchor.constraint(equalToConstant: 32).isActive = true
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

@MainActor
private final class AnnotationToolsHoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

private final class AnnotationActionButton: NSButton {
    var fillColor: NSColor?
    var titleColor: NSColor?
    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = fillColor ?? (isHighlighted ? NSColor(calibratedWhite: dark ? 0.23 : 0.90, alpha: 1) : NSColor.windowBackgroundColor)
        let foreground = titleColor ?? (dark ? NSColor.white : NSColor.black)
        let fill = isHighlighted ? background.blended(withFraction: 0.2, of: .black) ?? background : background
        fill.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).fill()
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: foreground.withAlphaComponent(alpha)])
        let iconSpace: CGFloat = image == nil ? 0 : 22
        let start = (bounds.width - text.size().width - iconSpace) / 2
        if let image {
            let icon = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [foreground]))) ?? image
            icon.draw(in: CGRect(x: start, y: bounds.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }
        text.draw(at: CGPoint(x: start + iconSpace, y: bounds.midY - text.size().height / 2))
    }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
}

@MainActor
private final class AnnotationSettingsHoverButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

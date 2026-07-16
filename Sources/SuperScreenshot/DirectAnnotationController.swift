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
    private var canvas: ScreenshotEditorView?
    private var mode: ScreenshotAnnotationMode = .arrow
    private var colorTarget: DirectColorTarget = .stroke
    private var arrowButton: ToolButton?
    private var textButton: ToolButton?
    private var rectangleButton: ToolButton?
    private var ellipseButton: ToolButton?
    private var textColorButton: NSButton?
    private var textBackgroundButton: NSButton?
    private var paletteButtons: [DirectColorButton] = []

    init(image: CGImage, selection: CGRect, screen: NSScreen) {
        self.image = image
        self.selection = selection
        self.screen = screen
    }

    func show() {
        let toolbarHeight: CGFloat = 100
        let visibleFrame = screen.visibleFrame
        let contentSize = CGSize(
            width: min(max(selection.width, 640), visibleFrame.width - 40),
            height: min(max(selection.height, 260) + toolbarHeight, visibleFrame.height - 40)
        )
        let origin = CGPoint(
            x: visibleFrame.midX - contentSize.width / 2,
            y: visibleFrame.midY - contentSize.height / 2
        )

        let canvasView = ScreenshotEditorView(frame: CGRect(x: 0, y: toolbarHeight, width: contentSize.width, height: contentSize.height - toolbarHeight), image: image)
        canvasView.autoresizingMask = [.width, .height]
        canvasView.mode = .arrow
        canvasView.strokeColor = loadColor("annotation.strokeColor", fallback: .systemRed)
        canvasView.textColor = loadColor("annotation.textColor", fallback: .white)
        canvasView.textBackgroundColor = loadColor("annotation.textBackgroundColor", fallback: .systemRed)
        canvasView.onEscape = { [weak self] in self?.cancel() }
        canvas = canvasView

        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "编辑截图"
        window.minSize = CGSize(width: 640, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating

        let content = NSView(frame: CGRect(origin: .zero, size: contentSize))
        content.autoresizingMask = [.width, .height]
        content.addSubview(canvasView)
        let toolbar = makeToolbarView(frame: CGRect(x: 0, y: 0, width: contentSize.width, height: toolbarHeight))
        toolbar.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(toolbar)
        window.contentView = content
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvasView)
        updateToolState()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        canvas = nil
    }

    private func makeToolbarView(frame: CGRect) -> NSView {
        let content = NSView(frame: frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.spacing = 8
        tools.alignment = .centerY
        tools.translatesAutoresizingMaskIntoConstraints = false

        tools.addArrangedSubview(button("撤销", action: #selector(undo)))
        arrowButton = toolButton("arrow.down.right", action: #selector(useArrow))
        textButton = toolButton("textformat", action: #selector(useText))
        rectangleButton = toolButton("rectangle", action: #selector(useRectangle))
        ellipseButton = toolButton("circle", action: #selector(useEllipse))
        [arrowButton, textButton, rectangleButton, ellipseButton].compactMap { $0 }.forEach { tools.addArrangedSubview($0) }
        tools.addArrangedSubview(button("长截图", action: #selector(longCapture)))
        let finishButton = ColoredTitleButton(title: "完成", fillColor: .systemGreen, textColor: .white, target: self, action: #selector(finish))
        finishButton.keyEquivalent = "\r"
        tools.addArrangedSubview(finishButton)

        let palette = NSStackView()
        palette.orientation = .horizontal
        palette.spacing = 8
        palette.alignment = .centerY
        palette.translatesAutoresizingMaskIntoConstraints = false
        let textColor = button("字色", action: #selector(useTextColor))
        let textBackground = button("背景", action: #selector(useTextBackground))
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
        NSLayoutConstraint.activate([
            tools.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            tools.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            palette.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            palette.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10)
        ])
        return content
    }

    private func toolButton(_ symbol: String, action: Selector) -> ToolButton {
        let button = ToolButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = NSColor.controlColor.cgColor
        button.contentTintColor = .labelColor
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
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
        textButton?.configure(top: canvas?.textColor ?? .white, bottom: canvas?.textBackgroundColor ?? .systemRed, selected: mode == .text)
        textColorButton?.isHidden = mode != .text
        textBackgroundButton?.isHidden = mode != .text
        textColorButton?.contentTintColor = colorTarget == .text ? .systemBlue : .labelColor
        textBackgroundButton?.contentTintColor = colorTarget == .textBackground ? .systemBlue : .labelColor
        let active = currentColor()
        paletteButtons.forEach { $0.isSelectedColor = colorsMatch($0.color, active) }
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

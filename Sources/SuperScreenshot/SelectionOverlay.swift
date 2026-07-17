import AppKit

@MainActor
final class SelectionOverlayController {
    var onSelection: ((CGRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    private let screens: [NSScreen]
    private var windows: [CaptureOverlayWindow] = []
    private var cursorPushed = false
    private let windowCandidates: [WindowCandidate]

    init(screens: [NSScreen]) {
        self.screens = screens
        self.windowCandidates = WindowCandidate.discover(on: screens)
    }

    func show() {
        for screen in screens {
            let window = CaptureOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.sharingType = .none
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true
            let candidates = windowCandidates.compactMap { candidate -> CGRect? in
                let clipped = candidate.frame.intersection(screen.frame)
                guard !clipped.isNull, clipped.width >= 10, clipped.height >= 10 else { return nil }
                return clipped.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            }
            let view = SelectionView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                windowFrames: candidates,
                colorSampler: ScreenColorSampler(screen: screen)
            )
            view.onCancel = { [weak self] in self?.onCancel?() }
            view.onSelection = { [weak self, weak window] local in
                guard let self, let window else { return }
                let global = window.convertToScreen(local)
                self.lockSelection()
                self.onSelection?(global, window.screen ?? screen)
            }
            window.contentView = view
            windows.append(window)
            window.orderFrontRegardless()
            let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            if view.bounds.contains(mouse) {
                view.updatePointer(at: mouse)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let activeWindow = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first
        activeWindow?.makeKeyAndOrderFront(nil)
        activeWindow?.makeFirstResponder(activeWindow?.contentView)
        NSCursor.crosshair.push()
        cursorPushed = true
    }

    private func lockSelection() {
        windows.forEach {
            ($0.contentView as? SelectionView)?.isLocked = true
            $0.ignoresMouseEvents = true
            $0.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        }
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

private final class ScreenColorSampler {
    private let bitmap: NSBitmapImageRep
    private let pointSize: CGSize

    init?(screen: NSScreen) {
        guard let displayID = ScreenCapture.displayID(for: screen),
              let image = CGDisplayCreateImage(displayID) else { return nil }
        bitmap = NSBitmapImageRep(cgImage: image)
        pointSize = screen.frame.size
    }

    func color(at point: CGPoint) -> NSColor? {
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        let x = min(bitmap.pixelsWide - 1, max(0, Int(point.x / pointSize.width * CGFloat(bitmap.pixelsWide))))
        let y = min(bitmap.pixelsHigh - 1, max(0, Int((pointSize.height - point.y) / pointSize.height * CGFloat(bitmap.pixelsHigh))))
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
    }
}

private struct WindowCandidate {
    let frame: CGRect

    @MainActor
    static func discover(on screens: [NSScreen]) -> [WindowCandidate] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            CGWindowID(kCGNullWindowID)
        ) as? [[String: Any]] else { return [] }
        let mainTop = screens.first(where: { $0.frame.contains(CGPoint(x: 1, y: 1)) })?.frame.maxY
            ?? screens.first?.frame.maxY
            ?? 0
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  isCapturableAppWindow(info),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  quartzFrame.width >= 40,
                  quartzFrame.height >= 40 else { return nil }
            let appKitFrame = CGRect(
                x: quartzFrame.minX,
                y: mainTop - quartzFrame.maxY,
                width: quartzFrame.width,
                height: quartzFrame.height
            )
            guard screens.contains(where: { $0.frame.intersects(appKitFrame) }) else { return nil }
            return WindowCandidate(frame: appKitFrame)
        }
    }

    @MainActor
    private static func isCapturableAppWindow(_ info: [String: Any]) -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID else {
            return true
        }
        guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let window = NSApp.windows.first(where: { $0.windowNumber == number }) else {
            return false
        }
        return window.sharingType != .none
    }
}

private final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        (contentView as? SelectionView)?.onCancel?()
    }
}

private final class SelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var selection: CGRect = .zero
    private let windowFrames: [CGRect]
    private var hoveredWindow: CGRect?
    private var pressedWindow: CGRect?
    private var isDraggingSelection = false
    private var trackingAreaRef: NSTrackingArea?
    private let colorSampler: ScreenColorSampler?
    private var pointerLocation: CGPoint?
    private var pointerColor: NSColor?
    var isLocked = false { didSet { needsDisplay = true } }

    init(frame frameRect: NSRect, windowFrames: [CGRect], colorSampler: ScreenColorSampler?) {
        self.windowFrames = windowFrames
        self.colorSampler = colorSampler
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.keyCode == 53 {
            onCancel?()
        } else if event.charactersIgnoringModifiers?.lowercased() == "c",
                  event.modifierFlags.intersection(blockedModifiers).isEmpty,
                  let value = currentColorValue() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func rightMouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        onCancel?()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard !isLocked, start == nil else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        updatePointer(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        guard start == nil else { return }
        hoveredWindow = nil
        pointerLocation = nil
        pointerColor = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        updatePointer(at: point)
        start = point
        pressedWindow = windowFrames.first(where: { $0.contains(point) })
        hoveredWindow = pressedWindow
        selection = .zero
        isDraggingSelection = false
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isLocked else { return }
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        updatePointer(at: end)
        guard isDraggingSelection || hypot(end.x - start.x, end.y - start.y) >= 3 else { return }
        isDraggingSelection = true
        hoveredWindow = nil
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !isLocked else { return }
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        defer {
            self.start = nil
            pressedWindow = nil
        }
        if hypot(end.x - start.x, end.y - start.y) >= 3 {
            isDraggingSelection = true
            hoveredWindow = nil
            selection = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        } else if let pressedWindow {
            selection = pressedWindow
        }
        guard selection.width >= 10, selection.height >= 10 else {
            updateHoveredWindow(at: convert(event.locationInWindow, from: nil))
            return
        }
        selection = ScreenCapture.pixelAligned(selection, scale: window?.backingScaleFactor ?? 1)
        needsDisplay = true
        isLocked = true
        onSelection?(selection)
    }
    private func updateHoveredWindow(at point: CGPoint) {
        let hovered = windowFrames.first(where: { $0.contains(point) })
        guard hovered != hoveredWindow else { return }
        hoveredWindow = hovered
        needsDisplay = true
    }
    func updatePointer(at point: CGPoint) {
        pointerLocation = point
        pointerColor = colorSampler?.color(at: point)
        updateHoveredWindow(at: point)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill(); bounds.fill()
        let highlighted = selection.isEmpty ? hoveredWindow : selection
        guard let highlighted, !highlighted.isEmpty else {
            guard !isLocked else { return }
            let text = L("单击窗口或拖动框选截图区域 · Esc 取消")
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 16, weight: .medium)
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attributes)
            drawColorReadout()
            return
        }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: highlighted).addClip()
        // Keep a minimally non-transparent hit surface. Fully transparent pixels in a
        // borderless window allow clicks to pass through to the window underneath.
        NSColor.black.withAlphaComponent(0.002).setFill(); highlighted.fill(using: .copy)
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.systemBlue.setStroke(); let border = NSBezierPath(rect: highlighted); border.lineWidth = 2; border.stroke()
        let size = "\(Int(highlighted.width)) × \(Int(highlighted.height))"
        size.draw(at: CGPoint(x: highlighted.minX, y: highlighted.maxY+6), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        drawColorReadout()
    }

    private func drawColorReadout() {
        guard !isLocked, let point = pointerLocation, let color = pointerColor else { return }
        guard let value = currentColorValue() else { return }
        let hint = L("按 C 复制当前色值")
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            .font: NSFont.systemFont(ofSize: 10)
        ]
        let hintWidth = ceil(hint.size(withAttributes: hintAttributes).width)
        let panelSize = CGSize(width: max(112, hintWidth + 14), height: 50)
        var origin = CGPoint(x: point.x + 14, y: point.y - panelSize.height - 14)
        if origin.x + panelSize.width > bounds.maxX - 6 { origin.x = point.x - panelSize.width - 14 }
        if origin.y < bounds.minY + 6 { origin.y = point.y + 14 }
        origin.x = min(max(origin.x, bounds.minX + 6), bounds.maxX - panelSize.width - 6)
        origin.y = min(max(origin.y, bounds.minY + 6), bounds.maxY - panelSize.height - 6)
        let panel = CGRect(origin: origin, size: panelSize)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 7, yRadius: 7).fill()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: panel.minX + 7, y: panel.minY + 27, width: 16, height: 16), xRadius: 4, yRadius: 4).fill()
        value.draw(
            at: CGPoint(x: panel.minX + 30, y: panel.minY + 27),
            withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ]
        )
        hint.draw(at: CGPoint(x: panel.minX + 7, y: panel.minY + 7), withAttributes: hintAttributes)
    }

    private func currentColorValue() -> String? {
        guard let color = pointerColor else { return nil }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

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
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), windowFrames: candidates)
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

private struct WindowCandidate {
    let frame: CGRect

    static func discover(on screens: [NSScreen]) -> [WindowCandidate] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            CGWindowID(kCGNullWindowID)
        ) as? [[String: Any]] else { return [] }
        let mainTop = screens.first(where: { $0.frame.contains(CGPoint(x: 1, y: 1)) })?.frame.maxY
            ?? screens.first?.frame.maxY
            ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
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
    private var isDraggingSelection = false
    private var trackingAreaRef: NSTrackingArea?
    var isLocked = false { didSet { needsDisplay = true } }

    init(frame frameRect: NSRect, windowFrames: [CGRect]) {
        self.windowFrames = windowFrames
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
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
        updateHoveredWindow(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        guard start == nil else { return }
        hoveredWindow = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        isDraggingSelection = false
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isLocked else { return }
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        guard isDraggingSelection || hypot(end.x - start.x, end.y - start.y) >= 3 else { return }
        isDraggingSelection = true
        hoveredWindow = nil
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !isLocked else { return }
        defer { start = nil }
        if !isDraggingSelection, let hoveredWindow {
            selection = hoveredWindow
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
            return
        }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: highlighted).addClip()
        NSColor.clear.setFill(); highlighted.fill(using: .copy)
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.systemBlue.setStroke(); let border = NSBezierPath(rect: highlighted); border.lineWidth = 2; border.stroke()
        let size = "\(Int(highlighted.width)) × \(Int(highlighted.height))"
        size.draw(at: CGPoint(x: highlighted.minX, y: highlighted.maxY+6), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }
}

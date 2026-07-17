import AppKit

@MainActor
final class SelectionOverlayController {
    var onSelection: ((CGRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    private let screens: [NSScreen]
    private var windows: [CaptureOverlayWindow] = []
    private var cursorPushed = false

    init(screens: [NSScreen]) { self.screens = screens }

    func show() {
        for screen in screens {
            let window = CaptureOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.sharingType = .none
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
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
    var isLocked = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        start = convert(event.locationInWindow, from: nil); selection = .zero; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isLocked else { return }
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !isLocked else { return }
        guard selection.width >= 10, selection.height >= 10 else { return }
        selection = ScreenCapture.pixelAligned(selection, scale: window?.backingScaleFactor ?? 1)
        needsDisplay = true
        isLocked = true
        onSelection?(selection)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill(); bounds.fill()
        guard !selection.isEmpty else {
            guard !isLocked else { return }
            let text = L("拖动鼠标框选截图区域 · Esc 取消")
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 16, weight: .medium)
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attributes)
            return
        }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        NSColor.clear.setFill(); selection.fill(using: .copy)
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.systemBlue.setStroke(); let border = NSBezierPath(rect: selection); border.lineWidth = 2; border.stroke()
        let size = "\(Int(selection.width)) × \(Int(selection.height))"
        size.draw(at: CGPoint(x: selection.minX, y: selection.maxY+6), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }
}

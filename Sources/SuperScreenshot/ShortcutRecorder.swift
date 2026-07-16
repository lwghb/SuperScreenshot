import AppKit

@MainActor
final class ShortcutRecorderController: NSObject {
    var onSave: ((CaptureShortcut) -> Void)?
    var onCancel: (() -> Void)?
    private let current: CaptureShortcut
    private var panel: NSPanel?
    private var monitor: Any?
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "请按下新的快捷键组合")

    init(current: CaptureShortcut) {
        self.current = current
    }

    func show() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 390, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "设置截图快捷键"
        panel.isReleasedWhenClosed = false

        shortcutLabel.stringValue = current.title
        shortcutLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        shortcutLabel.alignment = .center
        hintLabel.alignment = .center
        hintLabel.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelRecording))
        cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY

        let stack = NSStackView(views: [hintLabel, shortcutLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 18, right: 24)
        panel.contentView = stack
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.onCancel?()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            let modifiers = flags.intersection(allowed)
            guard !modifiers.isEmpty else {
                self.hintLabel.stringValue = "快捷键至少需要一个修饰键（⌘、⌃、⌥ 或 ⇧）"
                NSSound.beep()
                return nil
            }
            let shortcut = CaptureShortcut(
                keyCode: event.keyCode,
                modifiersRaw: modifiers.rawValue,
                keyLabel: Self.label(for: event)
            )
            self.shortcutLabel.stringValue = shortcut.title
            self.onSave?(shortcut)
            return nil
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func cancelRecording() { onCancel?() }

    private static func label(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "空格"
        case 51: return "⌫"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 119: return "↘"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let value = event.charactersIgnoringModifiers?.uppercased() ?? ""
            return value.isEmpty ? "键\(event.keyCode)" : value
        }
    }
}

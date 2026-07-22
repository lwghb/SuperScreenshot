import AppKit
import Foundation
import Sparkle

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let coordinator = CaptureCoordinator()
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu?
    private var recordingIndicatorTimer: Timer?
    private var shortcutItem: NSMenuItem!
    private var aboutWindowController: AboutWindowController?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusMenu()
        coordinator.installHotKeyMonitor { [weak self] in
            guard let self else { return }
            if self.coordinator.isRecordingOrStarting {
                if #available(macOS 13.0, *) { self.coordinator.toggleScreenRecording() }
            } else {
                self.coordinator.beginSelection()
            }
            self.statusItem.menu?.cancelTrackingWithoutAnimation()
        }
        coordinator.onRecordingStateChanged = { [weak self] recording in
            self?.updateStatusItem(recording: recording)
        }
    }

    private func installStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: L("超强截图"))
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: L("开始截图"), action: #selector(beginCapture), keyEquivalent: "")
        menu.addItem(.separator())
        shortcutItem = menu.addItem(withTitle: "", action: #selector(showShortcut), keyEquivalent: "")
        menu.addItem(withTitle: L("检查系统权限…"), action: #selector(checkPermissions), keyEquivalent: "")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let versionItem = menu.addItem(withTitle: LF("版本 %@", version), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        let updateItem = menu.addItem(withTitle: L("检查更新…"), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("关于超强截图…"), action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出超强截图"), action: #selector(quit), keyEquivalent: "")
        for item in menu.items { item.target = self }
        updateItem.target = updaterController
        statusMenu = menu
        statusItem.menu = menu
        updateShortcutTitle()
    }

    private func updateStatusItem(recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            button.image = recordingStopImage()
            button.contentTintColor = nil
            button.toolTip = L("结束录屏")
            button.target = self
            button.action = #selector(stopRecordingFromStatusItem)
            statusItem.menu = nil
            startRecordingIndicatorPulse()
        } else {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: L("超强截图"))
            button.contentTintColor = nil
            button.toolTip = L("超强截图")
            button.target = nil
            button.action = nil
            statusItem.menu = statusMenu
            recordingIndicatorTimer?.invalidate()
            recordingIndicatorTimer = nil
            button.alphaValue = 1
        }
    }

    private func startRecordingIndicatorPulse() {
        guard recordingIndicatorTimer == nil, let button = statusItem.button else { return }
        button.alphaValue = 1
        recordingIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggleRecordingIndicatorPulse() }
        }
    }

    private func toggleRecordingIndicatorPulse() {
        guard let button = statusItem.button, recordingIndicatorTimer != nil else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                button.animator().alphaValue = button.alphaValue > 0.8 ? 0.4 : 1
            }
    }

    private func recordingStopImage() -> NSImage {
        let image = NSImage(size: CGSize(width: 22, height: 22))
        image.lockFocus()
        let circle = NSRect(x: 1, y: 1, width: 20, height: 20)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
        outline.lineWidth = 1.5
        outline.stroke()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 7, y: 7, width: 8, height: 8), xRadius: 1.5, yRadius: 1.5).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func menuWillOpen(_ menu: NSMenu) { updateShortcutTitle() }
    private func updateShortcutTitle() {
        shortcutItem?.title = LF("设置快捷键…  %@", coordinator.shortcut.title)
    }
    @objc private func beginCapture() { coordinator.beginSelection() }
    @objc private func stopRecordingFromStatusItem() {
        if #available(macOS 13.0, *) { coordinator.toggleScreenRecording() }
    }
    @objc private func showShortcut() { coordinator.showShortcutSettings() }
    @objc private func checkPermissions() { coordinator.requestPermissions() }
    @objc private func showAbout() {
        if aboutWindowController == nil { aboutWindowController = AboutWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

import AppKit
import Foundation
import Sparkle

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let coordinator = CaptureCoordinator()
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu?
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
            let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: L("结束录屏"))
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = .systemRed
            button.toolTip = L("结束录屏")
            button.target = self
            button.action = #selector(stopRecordingFromStatusItem)
            statusItem.menu = nil
        } else {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: L("超强截图"))
            button.contentTintColor = nil
            button.toolTip = L("超强截图")
            button.target = nil
            button.action = nil
            statusItem.menu = statusMenu
        }
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

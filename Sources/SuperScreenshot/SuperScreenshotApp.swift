import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let coordinator = CaptureCoordinator()
    private var statusItem: NSStatusItem!
    private var shortcutItem: NSMenuItem!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.installHotKeyMonitor()
        installStatusMenu()
    }

    private func installStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "超强截图")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "开始截图", action: #selector(beginCapture), keyEquivalent: "")
        menu.addItem(.separator())
        shortcutItem = menu.addItem(withTitle: "", action: #selector(showShortcut), keyEquivalent: "")
        menu.addItem(withTitle: "检查系统权限…", action: #selector(checkPermissions), keyEquivalent: "")
        menu.addItem(.separator())
        let version = NSMenuItem(title: versionTitle(), action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出超强截图", action: #selector(quit), keyEquivalent: "")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        updateShortcutTitle()
    }

    func menuWillOpen(_ menu: NSMenu) { updateShortcutTitle() }
    private func updateShortcutTitle() {
        shortcutItem?.title = "设置快捷键…  \(coordinator.shortcut.title)"
    }
    private func versionTitle() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "未知"
        return "版本 \(version)"
    }
    @objc private func beginCapture() { coordinator.beginSelection() }
    @objc private func showShortcut() { coordinator.showShortcutSettings() }
    @objc private func checkPermissions() { coordinator.requestPermissions() }
    @objc private func quit() { NSApp.terminate(nil) }
}

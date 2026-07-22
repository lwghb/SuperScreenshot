import AppKit
import ApplicationServices
import CoreGraphics

private func performAutomaticScrollStep(distance: Int) async {
    let pulseCount = 16
    let baseDistance = distance / pulseCount
    let remainder = distance % pulseCount
    for index in 0..<pulseCount {
        let pulseDistance = baseDistance + (index < remainder ? 1 : 0)
        autoreleasepool {
            if let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: Int32(-pulseDistance),
                wheel2: 0,
                wheel3: 0
            ) {
                event.post(tap: .cghidEventTap)
            }
        }
        if index < pulseCount - 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

struct CaptureShortcut: Equatable {
    let keyCode: UInt16
    let modifiersRaw: UInt
    let keyLabel: String

    static let defaultShortcut = CaptureShortcut(
        keyCode: 19,
        modifiersRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        keyLabel: "2"
    )

    var title: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiersRaw)
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    func matches(_ event: NSEvent) -> Bool {
        let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let flags = event.modifierFlags.intersection(allowed)
        let expected = NSEvent.ModifierFlags(rawValue: modifiersRaw).intersection(allowed)
        return event.keyCode == keyCode && flags == expected
    }
}

@MainActor
final class CaptureCoordinator: ObservableObject {
    var onRecordingStateChanged: ((Bool) -> Void)?
    @Published var shortcut: CaptureShortcut {
        didSet {
            UserDefaults.standard.set(Int(shortcut.keyCode), forKey: "shortcutKeyCode")
            UserDefaults.standard.set(Int(shortcut.modifiersRaw), forKey: "shortcutModifiers")
            UserDefaults.standard.set(shortcut.keyLabel, forKey: "shortcutKeyLabel")
            hotKeyManager.register(shortcut)
        }
    }

    private lazy var hotKeyManager = GlobalHotKeyManager()
    private var selectionController: SelectionOverlayController?
    private var selectionSnapshots: [CGDirectDisplayID: CGImage] = [:]
    private var actionController: ActionBarController?
    private var directAnnotationController: DirectAnnotationController?
    private var longStatusController: LongCaptureStatusController?
    private var longCaptureControl: LongCaptureControl?
    private var longSelectionBorder: SelectionBorderController?
    private var shortcutRecorder: ShortcutRecorderController?
    private var editorController: ScreenshotEditorController?
    private var isCheckingCaptureAccess = false
    private var isAutoScrolling = false
    private var autoScrollOriginalMouseLocation: CGPoint?
    private let longCapture = LongCaptureEngine()
    private var screenRecorder: AnyObject?
    private var recordingSelection: CGRect?
    private var recordingScreen: NSScreen?
    private var recordingFrameRate: RecordingFrameRate = .standard
    private var recordingBitRate = 1_000_000
    private var recordingToolbar: RecordingToolbarController?
    private var recordingEditor: RecordingEditorController?

    var isRecordingOrStarting: Bool { screenRecorder != nil }

    init() {
        if let label = UserDefaults.standard.string(forKey: "shortcutKeyLabel") {
            shortcut = CaptureShortcut(
                keyCode: UInt16(UserDefaults.standard.integer(forKey: "shortcutKeyCode")),
                modifiersRaw: UInt(UserDefaults.standard.integer(forKey: "shortcutModifiers")),
                keyLabel: label
            )
        } else {
            shortcut = .defaultShortcut
        }
    }

    func showShortcutSettings() {
        shortcutRecorder?.close()
        let recorder = ShortcutRecorderController(current: shortcut)
        shortcutRecorder = recorder
        recorder.onSave = { [weak self] newShortcut in
            self?.shortcut = newShortcut
            self?.shortcutRecorder?.close()
            self?.shortcutRecorder = nil
        }
        recorder.onCancel = { [weak self] in
            self?.shortcutRecorder?.close()
            self?.shortcutRecorder = nil
        }
        recorder.show()
    }

    func installHotKeyMonitor(onPressed: (() -> Void)? = nil) {
        hotKeyManager.onPressed = { [weak self] in
            guard let self else { return }
            if let onPressed {
                onPressed()
            } else {
                self.beginSelection()
            }
        }
        hotKeyManager.register(shortcut)
    }

    func requestPermissions() {
        if CGPreflightScreenCaptureAccess() {
            let alert = NSAlert()
            alert.messageText = L("屏幕录制权限有效")
            alert.informativeText = L("超强截图已经可以读取屏幕内容。")
            alert.addButton(withTitle: L("好"))
            alert.runModal()
        } else {
            let granted = CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            if granted {
                alert.messageText = L("屏幕录制权限已授予")
                alert.informativeText = L("请彻底退出并重新打开“超强截图”，让系统权限生效。")
                alert.addButton(withTitle: L("退出应用"))
                alert.runModal()
                NSApp.terminate(nil)
            } else {
                alert.messageText = L("需要屏幕录制权限")
                alert.informativeText = L("请在系统设置的“隐私与安全性 → 录屏与系统录音”中允许“超强截图”。")
                alert.addButton(withTitle: L("打开系统设置"))
                alert.addButton(withTitle: L("关闭"))
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @available(macOS 13.0, *)
    func toggleScreenRecording() {
        guard let recorder = screenRecorder as? ScreenRecorder else {
            return startScreenRecording(on: NSScreen.main)
        }
        // The start call is asynchronous. If the user ends immediately, wait
        // for ScreenCaptureKit to become active instead of starting a second
        // recorder and leaving the stop action with no visible result.
        if !recorder.isRecording {
            Task { @MainActor [weak self, weak recorder] in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if recorder?.isRecording == true {
                        self?.toggleScreenRecording()
                        return
                    }
                }
            }
            return
        }
        if recorder.isRecording {
            Task { @MainActor in
                let url = try? await recorder.stop()
                self.screenRecorder = nil
                self.recordingToolbar?.close()
                self.recordingToolbar = nil
                self.onRecordingStateChanged?(false)
                guard let url else {
                    let alert = NSAlert()
                    alert.messageText = L("录屏保存失败")
                    alert.informativeText = recorder.lastErrorDescription ?? L("录屏未能完成视频文件写入，请重试。")
                    alert.addButton(withTitle: L("好"))
                    alert.runModal()
                    return
                }
                self.recordingSelection = nil
                let editor = RecordingEditorController(
                    url: url,
                    screen: self.recordingScreen ?? NSScreen.main ?? NSScreen.screens[0],
                    frameRate: self.recordingFrameRate.rawValue,
                    bitRate: self.recordingBitRate
                )
                self.recordingEditor = editor
                editor.show()
            }
            return
        }
        startScreenRecording(on: NSScreen.main)
    }

    @available(macOS 13.0, *)
    private func startScreenRecording(on screen: NSScreen?, frameRate: RecordingFrameRate = .standard, bitRate: Int = 1_000_000) {
        guard let screen else { return }
        recordingScreen = screen
        recordingFrameRate = frameRate
        recordingBitRate = bitRate
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("superscreenshot-recording-\(UUID().uuidString).mp4")
        let recorder = ScreenRecorder()
        screenRecorder = recorder
        Task { @MainActor in
            do {
                try await recorder.start(
                    screen: screen,
                    selection: self.recordingSelection,
                    options: ScreenRecordingOptions(frameRate: frameRate, bitRate: bitRate),
                    outputURL: url
                )
                self.onRecordingStateChanged?(true)
            } catch {
                self.screenRecorder = nil
                self.onRecordingStateChanged?(false)
            }
        }
    }

    func beginSelection() {
        guard selectionController == nil, !isCheckingCaptureAccess else { return }
        selectionSnapshots = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let displayID = ScreenCapture.displayID(for: screen),
                  let image = ScreenCapture.displaySnapshot(for: screen) else { return nil }
            return (displayID, image)
        })
        isCheckingCaptureAccess = true
        Task {
            defer { isCheckingCaptureAccess = false }
            do {
                try await ScreenCapture.verifyAccess()
                showSelectionOverlay()
            } catch {
                showPermissionError(error)
            }
        }
    }

    private func showSelectionOverlay() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let controller = SelectionOverlayController(screens: screens, snapshots: selectionSnapshots)
        selectionController = controller
        controller.onCancel = { [weak self] in self?.closeOverlays() }
        controller.onSelection = { [weak self] rect, screen in self?.showActions(for: rect, on: screen) }
        controller.show()
    }

    private func showActions(for rect: CGRect, on screen: NSScreen) {
        if let displayID = ScreenCapture.displayID(for: screen),
           let snapshot = selectionSnapshots[displayID],
           let image = ScreenCapture.crop(snapshot, to: rect, on: screen) {
            presentDirectAnnotation(image: image, rect: rect, screen: screen)
            return
        }
        Task {
            guard let image = await capture(rect: rect, screen: screen, preserveSelectionOverlay: true) else {
                closeOverlays()
                return
            }
            await MainActor.run {
                self.presentDirectAnnotation(image: image, rect: rect, screen: screen)
            }
        }
    }

    private func presentDirectAnnotation(image: CGImage, rect: CGRect, screen: NSScreen) {
        directAnnotationController?.close()
        let fullScreenImage = ScreenCapture.displayID(for: screen).flatMap { selectionSnapshots[$0] }
        let controller = DirectAnnotationController(
            image: image,
            selection: rect,
            screen: screen,
            fullScreenImage: fullScreenImage
        )
        directAnnotationController = controller
        controller.onSelectionChanged = { [weak self] selection in
            self?.selectionController?.updateLockedSelection(selection, on: screen)
        }
        controller.onScreenRecording = { [weak self] selection in
            guard let self else { return }
            self.directAnnotationController?.transitionToRecordingToolbar { [weak self] sourceFrame in
                guard let self else { return }
                self.directAnnotationController?.close()
                self.directAnnotationController = nil
                self.selectionController?.close()
                self.selectionController = nil
                self.recordingSelection = selection
                if #available(macOS 13.0, *) {
                    let toolbar = RecordingToolbarController()
                    self.recordingToolbar = toolbar
                    toolbar.onStart = { [weak self] frameRate, bitRate in
                        self?.startScreenRecording(on: screen, frameRate: frameRate, bitRate: bitRate)
                    }
                    toolbar.onStop = { [weak self, weak toolbar] in
                        toolbar?.close()
                        self?.toggleScreenRecording()
                        self?.longSelectionBorder?.close()
                        self?.longSelectionBorder = nil
                    }
                    toolbar.onHide = { [weak self, weak toolbar] in
                        toolbar?.hideWhileRecording()
                        self?.onRecordingStateChanged?(true)
                    }
                    toolbar.onBack = { [weak self] in
                        guard let self else { return }
                        self.recordingToolbar?.dismissForBack { [weak self] in
                            guard let self else { return }
                            self.recordingToolbar = nil
                            self.longSelectionBorder?.close()
                            self.longSelectionBorder = nil
                            self.recordingSelection = nil
                            self.presentDirectAnnotation(image: image, rect: selection, screen: screen)
                        }
                    }
                    toolbar.show(in: screen, below: selection, from: sourceFrame)
                    let border = SelectionBorderController(selection: selection)
                    self.longSelectionBorder = border
                    border.show()
                }
            }
        }
        controller.onFinish = { [weak self] edited in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: edited, size: .zero)])
            self?.directAnnotationController?.close()
            self?.directAnnotationController = nil
            self?.closeOverlays()
        }
        controller.onLongCapture = { [weak self] selection in
            self?.directAnnotationController?.close()
            self?.directAnnotationController = nil
            self?.closeOverlays()
            self?.startLongCapture(rect: selection, screen: screen)
        }
        controller.onCancel = { [weak self] in
            self?.directAnnotationController?.close()
            self?.directAnnotationController = nil
            self?.closeOverlays()
        }
        controller.show()
    }

    private func capture(rect: CGRect, screen: NSScreen, preserveSelectionOverlay: Bool = false) async -> CGImage? {
        guard let displayID = ScreenCapture.displayID(for: screen) else { return nil }
        let sourceRect = ScreenCapture.displayRect(for: rect, on: screen)
        let scale = screen.backingScaleFactor
        if !preserveSelectionOverlay {
            closeOverlays()
            try? await Task.sleep(nanoseconds: 220_000_000)
        }
        do {
            let session = try await ScreenCapture.makeSession(
                displayID: displayID,
                sourceRect: sourceRect,
                scale: scale
            )
            return try await session.capture()
        } catch {
            showPermissionError(error)
            return nil
        }
    }

    private func edit(rect: CGRect, screen: NSScreen) {
        Task {
            guard let image = await capture(rect: rect, screen: screen) else { return }
            await MainActor.run {
                self.presentEditor(image, on: screen)
            }
        }
    }

    private func copy(rect: CGRect, screen: NSScreen) {
        Task {
            guard let image = await capture(rect: rect, screen: screen) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
        }
    }

    private func presentEditor(_ image: CGImage, on screen: NSScreen) {
        editorController?.close()
        let editor = ScreenshotEditorController(image: image, initialMode: .arrow, screen: screen)
        editorController = editor
        editor.onFinish = { [weak self] edited in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: edited, size: .zero)])
            self?.editorController?.close()
            self?.editorController = nil
        }
        editor.onCancel = { [weak self] in
            self?.editorController?.close()
            self?.editorController = nil
        }
        editor.show()
    }

    private func startLongCapture(rect: CGRect, screen: NSScreen) {
        guard let displayID = ScreenCapture.displayID(for: screen) else { return }
        let displayRect = ScreenCapture.displayRect(for: rect, on: screen)
        let scale = screen.backingScaleFactor
        closeOverlays()
        let border = SelectionBorderController(selection: rect)
        longSelectionBorder = border
        border.show()
        let control = LongCaptureControl()
        longCaptureControl = control
        let status = LongCaptureStatusController(selection: rect, screen: screen)
        longStatusController = status
        status.onFinish = { [weak self] in
            self?.stopAutoScroll()
            Task { await control.finish() }
        }
        status.onCancel = { [weak self] in
            self?.stopAutoScroll()
            Task { await control.cancel() }
        }
        status.onAutoScrollToggle = { [weak self] in
            self?.toggleAutoScroll(displayID: displayID, displayRect: displayRect)
        }
        status.show()
        Task {
            do {
                let session = try await ScreenCapture.makeSession(
                    displayID: displayID,
                    sourceRect: displayRect,
                    scale: scale
                )
                let image = try await longCapture.capture(
                    session: session,
                    control: control,
                    onAutoScrollStep: {
                        let distance = max(1, Int((80 / max(1, scale)).rounded()))
                        await performAutomaticScrollStep(distance: distance)
                    }
                ) { preview in
                    Task { @MainActor in status.update(preview: preview) }
                }
                await MainActor.run {
                    self.closeLongCaptureStatus()
                    self.presentLongCaptureResult(image)
                }
            } catch is CancellationError {
                await MainActor.run { self.closeLongCaptureStatus() }
            } catch {
                await MainActor.run {
                    self.closeLongCaptureStatus()
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func presentLongCaptureResult(_ image: CGImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
    }

    private func closeLongCaptureStatus() {
        stopAutoScroll()
        longStatusController?.close(); longStatusController = nil
        longSelectionBorder?.close(); longSelectionBorder = nil
        longCaptureControl = nil
    }

    private func toggleAutoScroll(
        displayID: CGDirectDisplayID,
        displayRect: CGRect
    ) {
        if isAutoScrolling {
            stopAutoScroll()
            return
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            let alert = NSAlert()
            alert.messageText = L("自动滚动需要辅助功能权限")
            alert.informativeText = L("请在系统设置的“隐私与安全性 → 辅助功能”中允许“超强截图”，然后再次点击自动滚动。手动长截图不受影响。")
            alert.addButton(withTitle: L("打开系统设置"))
            alert.addButton(withTitle: L("关闭"))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        autoScrollOriginalMouseLocation = CGEvent(source: nil)?.location
        let displayBounds = CGDisplayBounds(displayID)
        let target = CGPoint(
            x: displayBounds.minX + displayRect.midX,
            y: displayBounds.minY + displayRect.midY
        )
        CGWarpMouseCursorPosition(target)
        isAutoScrolling = true
        longStatusController?.setAutoScrolling(true)
        if let control = longCaptureControl {
            Task { await control.setAutoScrolling(true) }
        }
    }

    private func stopAutoScroll() {
        isAutoScrolling = false
        if let control = longCaptureControl {
            Task { await control.setAutoScrolling(false) }
        }
        if let original = autoScrollOriginalMouseLocation {
            CGWarpMouseCursorPosition(original)
        }
        autoScrollOriginalMouseLocation = nil
        longStatusController?.setAutoScrolling(false)
    }

    private func closeOverlays() {
        selectionController?.close(); selectionController = nil
        actionController?.close(); actionController = nil
        directAnnotationController?.close(); directAnnotationController = nil
        selectionSnapshots.removeAll()
    }

    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = L("操作失败"); alert.informativeText = message; alert.runModal()
    }

    private func showPermissionError(_ error: Error) {
        let alert = NSAlert()
        if CGPreflightScreenCaptureAccess() {
            alert.messageText = L("无法读取屏幕内容")
            alert.informativeText = LF("系统已经显示“超强截图”有录屏权限，但本次截图仍然失败：%@\n\n请彻底退出并重新打开“超强截图”。如果仍然失败，把系统设置里的“超强截图”关闭再打开一次。", error.localizedDescription)
            alert.addButton(withTitle: L("好"))
            alert.runModal()
        } else {
            alert.messageText = L("需要屏幕录制权限")
            alert.informativeText = LF("请在系统设置的“隐私与安全性 → 录屏与系统录音”中允许“超强截图”。\n\n系统返回：%@", error.localizedDescription)
            alert.addButton(withTitle: L("打开系统设置"))
            alert.addButton(withTitle: L("关闭"))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

}

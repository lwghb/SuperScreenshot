import AppKit
import Testing
@testable import SuperScreenshot

struct RecordingPreferencesTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SuperScreenshotTests.\(UUID().uuidString)")!
    }

    @Test func restoresDefaultsAndAllSavedOptions() {
        let defaults = isolatedDefaults()
        var preferences = RecordingPreferences(defaults: defaults)
        #expect(preferences.frameRate == .standard)
        #expect(preferences.bitRateMbps == 1)
        #expect(!preferences.capturesSystemAudio)
        preferences.frameRate = .high
        preferences.bitRateMbps = 32.5
        preferences.capturesSystemAudio = true
        preferences.save(to: defaults)
        let restored = RecordingPreferences(defaults: defaults)
        #expect(restored.frameRate == .high)
        #expect(restored.bitRateMbps == 32.5)
        #expect(restored.capturesSystemAudio)
    }

    @Test func adaptsSavedHighFrameRateAndBitrateWithoutChangingPreferences() {
        var preferences = RecordingPreferences(defaults: isolatedDefaults())
        preferences.frameRate = .high
        preferences.bitRateMbps = 60
        let size = CGSize(width: 640, height: 480)
        #expect(preferences.effectiveFrameRate(supportsHighFrameRate: false) == .standard)
        #expect(preferences.effectiveFrameRate(supportsHighFrameRate: true) == .high)
        #expect(preferences.effectiveBitRateMbps(pixelSize: size, supportsHighFrameRate: false) == 5.2)
        #expect(preferences.effectiveBitRateMbps(pixelSize: size, supportsHighFrameRate: true) == 10.4)
        #expect(preferences.frameRate == .high)
        #expect(preferences.bitRateMbps == 60)
        #expect(RecordingPreferences.maximumBitRateMbps(pixelSize: .zero, frameRate: .low) == 1)
        #expect(RecordingPreferences.maximumBitRateMbps(pixelSize: CGSize(width: 7680, height: 4320), frameRate: .high) == 60)
    }

    @Test func sanitizesInvalidSavedOptions() {
        let defaults = isolatedDefaults()
        defaults.set(90, forKey: "recording.frameRate")
        defaults.set(Double.nan, forKey: "recording.bitRateMbps")
        let preferences = RecordingPreferences(defaults: defaults)
        #expect(preferences.frameRate == .standard)
        #expect(preferences.bitRateMbps == 1)
    }
}

@MainActor
@Suite(.serialized)
struct RecordingToolbarInteractionTests {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @Test func compactActionsAndIntegratedSettingsHaveIndependentHitAreas() throws {
        let toolbar = SharedAnnotationToolbar(frame: CGRect(x: 0, y: 0, width: 348, height: 48), showsCaptureActions: true, showsFinish: true)
        let window = NSWindow(contentRect: toolbar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = toolbar
        defer { window.orderOut(nil) }
        toolbar.update(canvas: nil, mode: .arrow, colorTarget: .stroke, hasAnnotations: false)
        toolbar.layoutSubtreeIfNeeded()
        let buttons = descendants(toolbar).compactMap { $0 as? NSButton }
        let recording = try #require(buttons.first { $0.identifier?.rawValue == "recording.start" })
        let settings = try #require(buttons.first { $0.identifier?.rawValue == "recording.settings" })
        let long = try #require(buttons.first { $0.identifier?.rawValue == "capture.scrolling" })
        let undo = try #require(buttons.first { $0.identifier?.rawValue == "annotation.undo" })
        let recordRect = recording.convert(recording.bounds, to: toolbar)
        let settingsRect = settings.convert(settings.bounds, to: toolbar)
        #expect(recordRect.height == 48 && long.frame.height == 48)
        #expect(recordRect.contains(settingsRect))
        #expect(settingsRect.midX > recordRect.midX && settingsRect.midY > recordRect.midY)
        #expect(undo.isHiddenOrHasHiddenAncestor && undo.title.isEmpty && undo.image != nil)
        #expect(toolbar.hitTest(settings.convert(CGPoint(x: settings.bounds.midX, y: settings.bounds.midY), to: toolbar.superview)) === settings)
        var starts = 0
        var opens = 0
        toolbar.onScreenRecording = { starts += 1 }
        toolbar.onRecordingSettings = { opens += 1 }
        settings.performClick(nil)
        #expect(opens == 1 && starts == 0)
        recording.performClick(nil)
        #expect(starts == 1)
        try capture(toolbar, to: "/tmp/SuperScreenshot-toolbar-redesign-default.png")
        toolbar.update(canvas: nil, mode: .arrow, colorTarget: .stroke, hasAnnotations: true)
        // Finish any size transition before checking the operated layout.
        toolbar.setToolPickerExpanded(true, animated: false)
        toolbar.setToolPickerExpanded(false, animated: false)
        #expect(!undo.isHiddenOrHasHiddenAncestor)
        try capture(toolbar, to: "/tmp/SuperScreenshot-toolbar-redesign-undo.png")
    }

    @Test func hoverDelayRightClickAndScreenAnchorMatchApprovedLayout() async throws {
        let toolbar = SharedAnnotationToolbar(frame: CGRect(x: 0, y: 0, width: 348, height: 48), showsCaptureActions: true, showsFinish: true)
        let screen = try #require(NSScreen.main)
        let window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX - 174, y: screen.visibleFrame.midY, width: 348, height: 48), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = toolbar
        defer { toolbar.closeTransientUI(); window.orderOut(nil) }
        toolbar.update(canvas: nil, mode: .arrow, colorTarget: .stroke, hasAnnotations: false)
        toolbar.layoutSubtreeIfNeeded()
        toolbar.onMode = { [weak toolbar] mode in toolbar?.update(canvas: nil, mode: mode, colorTarget: mode == .text ? .text : .stroke, hasAnnotations: false) }
        let hover = try #require(descendants(toolbar).first { $0.identifier?.rawValue == "annotation.hover" })
        let choices = try #require(descendants(toolbar).first { $0.identifier?.rawValue == "annotation.choices" })
        let recent = try #require(descendants(toolbar).compactMap { $0 as? ToolButton }.first { $0.identifier?.rawValue == "annotation.recent" })
        let text = try #require(descendants(choices).compactMap { $0 as? ToolButton }.first { $0.tag == ScreenshotAnnotationMode.text.rawValue })
        let arrow = try #require(descendants(choices).compactMap { $0 as? ToolButton }.first { $0.tag == ScreenshotAnnotationMode.arrow.rawValue })
        func screenX(_ view: NSView) -> CGFloat { window.convertPoint(toScreen: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)).x }
        #expect(!toolbar.isToolPickerExpanded && choices.isHidden && !toolbar.isExpanded)
        #expect(recent.tag == ScreenshotAnnotationMode.arrow.rawValue && recent.layer?.shadowOpacity == 0)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        hover.mouseEntered(with: event)
        #expect(toolbar.isExpanded && !toolbar.isToolPickerExpanded)
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(!toolbar.isToolPickerExpanded)
        hover.mouseExited(with: event)
        try await Task.sleep(nanoseconds: 750_000_000)
        #expect(!toolbar.isToolPickerExpanded && !toolbar.isExpanded)
        let originalX = screenX(recent)
        hover.mouseEntered(with: event)
        try await Task.sleep(nanoseconds: 850_000_000)
        #expect(!toolbar.isToolPickerExpanded)
        try await Task.sleep(nanoseconds: 230_000_000)
        #expect(toolbar.isToolPickerExpanded)
        #expect(abs(screenX(arrow) - originalX) < 1)
        try await Task.sleep(nanoseconds: 220_000_000)
        #expect(abs(screenX(arrow) - originalX) < 1)
        try capture(toolbar, to: "/tmp/SuperScreenshot-approved-tools.png")
        text.performClick(nil)
        let selectedX = screenX(text)
        try await Task.sleep(nanoseconds: 260_000_000)
        #expect(!toolbar.isToolPickerExpanded && choices.isHidden)
        #expect(recent.tag == ScreenshotAnnotationMode.text.rawValue && toolbar.isExpanded)
        #expect(abs(screenX(recent) - selectedX) < 1)
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        recent.rightMouseDown(with: rightClick)
        #expect(toolbar.isToolPickerExpanded)
        try await Task.sleep(nanoseconds: 260_000_000)
        hover.mouseExited(with: event)
        toolbar.parameterContentView.mouseEntered(with: event)
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(toolbar.isExpanded)
        toolbar.parameterContentView.mouseExited(with: event)
        try await Task.sleep(nanoseconds: 450_000_000)
        #expect(!toolbar.isExpanded && !toolbar.isToolPickerExpanded)
        #expect(toolbar.displayedHeight == 48)
    }

    private func capture(_ toolbar: NSView, to path: String) throws {
        toolbar.layoutSubtreeIfNeeded()
        if let bitmap = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) {
            toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func settingsBubbleIsAnchoredAndDoesNotStartRecording() throws {
        let screen = try #require(NSScreen.main)
        let toolbar = SharedAnnotationToolbar(frame: CGRect(x: 0, y: 0, width: 348, height: 48), showsCaptureActions: true, showsFinish: true)
        let window = NSWindow(contentRect: CGRect(x: screen.frame.midX - 206, y: screen.frame.midY, width: 348, height: 48), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = toolbar
        toolbar.update(canvas: nil, mode: .arrow, colorTarget: .stroke, hasAnnotations: false)
        toolbar.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        let settings = RecordingToolbarController()
        defer { settings.close(); window.orderOut(nil) }
        var starts = 0
        settings.onStart = { _, _, _ in starts += 1 }
        let anchor = try #require(toolbar.recordingSettingsAnchor)
        settings.show(in: screen, below: CGRect(x: screen.frame.midX - 100, y: screen.frame.midY + 100, width: 200, height: 200), settingsOnly: true, settingsAnchor: anchor)
        #expect(settings.isSettingsVisible && starts == 0)
        let bubble = try #require(NSApp.windows.first { candidate in
            candidate !== window && candidate.isVisible && candidate.contentView.map { descendants($0).contains { ($0 as? NSButton)?.title == L("系统声音") } } == true
        })
        let content = try #require(bubble.contentView)
        content.layoutSubtreeIfNeeded()
        try capture(content, to: "/tmp/SuperScreenshot-recording-settings-bubble.png")
        settings.close()
        #expect(!settings.isSettingsVisible && starts == 0)
    }

    @Test func immediateStartSubmitsOnceWithSavedEffectiveOptions() throws {
        let screen = try #require(NSScreen.main)
        let toolbar = RecordingToolbarController()
        defer { toolbar.close() }
        var starts = 0
        let preferences = RecordingPreferences()
        toolbar.onStart = { rate, bitrate, audio in
            starts += 1
            #expect(rate == preferences.effectiveFrameRate(supportsHighFrameRate: false) || rate == preferences.frameRate)
            #expect(bitrate >= 1_000_000 && bitrate <= 60_000_000)
            #expect(audio == preferences.capturesSystemAudio)
        }
        toolbar.show(in: screen, below: CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 100, width: 200, height: 200), startImmediately: true)
        #expect(starts == 1)
        toolbar.recordingDidStart()
        #expect(starts == 1)
    }

    @Test func settingsDoNotStartRecordingAndDoneCloses() async throws {
        let screen = try #require(NSScreen.main)
        let toolbar = RecordingToolbarController()
        defer { toolbar.close() }
        var starts = 0
        var closes = 0
        toolbar.onStart = { _, _, _ in starts += 1 }
        toolbar.onBack = { [weak toolbar] in closes += 1; toolbar?.close() }
        toolbar.show(in: screen, below: CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 100, width: 200, height: 200), settingsOnly: true)
        #expect(starts == 0)
        let panel = try #require(NSApp.windows.first { window in
            window.isVisible && window.contentView.map { descendants($0).contains { ($0 as? NSButton)?.title == L("完成") } } == true
        })
        let content = try #require(panel.contentView)
        let done = try #require(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L("完成") })
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/SuperScreenshot-recording-settings.png"))
        }
        done.performClick(nil)
        await Task.yield()
        #expect(starts == 0)
        #expect(closes == 1)
    }
}

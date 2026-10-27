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

    @Test func leftRecordingActionAndSettingsHaveIndependentCallbacksAndRoom() throws {
        let toolbar = SharedAnnotationToolbar(frame: CGRect(x: 0, y: 0, width: 860, height: 100), showsCaptureActions: true, showsFinish: true)
        let window = NSWindow(contentRect: toolbar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = toolbar
        defer { window.orderOut(nil) }
        toolbar.update(canvas: nil, mode: .brush, colorTarget: .stroke, hasAnnotations: true)
        toolbar.layoutSubtreeIfNeeded()
        let buttons = descendants(toolbar).compactMap { $0 as? NSButton }
        let recording = try #require(buttons.first { $0.title == L("录屏") })
        let settings = try #require(buttons.first { $0.identifier?.rawValue == "recording.settings" })
        #expect(recording.frame.minX == 12)
        #expect(recording.frame.height >= 76)
        #expect(recording.frame.width >= 96)
        #expect(settings.frame.minX > recording.frame.maxX)
        var starts = 0
        var opens = 0
        toolbar.onScreenRecording = { starts += 1 }
        toolbar.onRecordingSettings = { opens += 1 }
        settings.performClick(nil)
        #expect(opens == 1 && starts == 0)
        recording.performClick(nil)
        #expect(starts == 1)
        for child in descendants(toolbar) where !child.isHiddenOrHasHiddenAncestor && (child is NSButton || child is NSSlider) {
            let rect = child.convert(child.bounds, to: toolbar)
            #expect(toolbar.bounds.contains(rect))
            if child !== recording && child !== settings {
                #expect(!rect.intersects(recording.frame))
                #expect(!rect.intersects(settings.frame))
            }
        }
        toolbar.update(canvas: nil, mode: .text, colorTarget: .text, hasAnnotations: true)
        toolbar.layoutSubtreeIfNeeded()
        for child in descendants(toolbar) where !child.isHiddenOrHasHiddenAncestor && (child is NSButton || child is NSSlider) {
            let rect = child.convert(child.bounds, to: toolbar)
            #expect(toolbar.bounds.contains(rect))
            if child !== recording && child !== settings {
                #expect(!rect.intersects(recording.frame))
                #expect(!rect.intersects(settings.frame))
            }
        }
        if let bitmap = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) {
            toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/SuperScreenshot-recording-toolbar.png"))
        }
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

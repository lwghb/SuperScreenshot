import AppKit
import AVFoundation
import AVKit

@MainActor
final class RecordingEditorController: NSObject {
    private let url: URL
    private let asset: AVURLAsset
    private let player: AVPlayer
    private var panel: NSPanel?
    private var trimRangeView: RecordingTrimRangeView!
    private var duration: Double = 0

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
        player = AVPlayer(url: url)
    }

    func show() {
        duration = max(asset.duration.seconds, 0.1)
        let size = CGSize(width: 820, height: 590)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L("编辑录屏")
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.level = .floating

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let preview = AVPlayerView(frame: CGRect(x: 24, y: 164, width: 772, height: 400))
        preview.player = player
        preview.controlsStyle = .none
        preview.videoGravity = .resizeAspect
        content.addSubview(preview)

        let caption = NSTextField(labelWithString: L("拖动起点和终点，选择需要保留的录屏片段"))
        caption.font = .systemFont(ofSize: 13)
        caption.textColor = .secondaryLabelColor
        caption.frame = CGRect(x: 32, y: 126, width: 560, height: 20)
        content.addSubview(caption)

        let trimRange = RecordingTrimRangeView(frame: CGRect(x: 32, y: 70, width: 764, height: 38))
        trimRange.duration = duration
        trimRange.end = duration
        trimRange.onPreview = { [weak self] seconds in
            self?.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        trimRangeView = trimRange
        content.addSubview(trimRange)

        let save = NSButton(title: L("保存"), target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.bezelColor = .systemBlue
        save.contentTintColor = .white
        save.keyEquivalent = "\r"
        save.frame = CGRect(x: 558, y: 18, width: 108, height: 32)
        let copy = NSButton(title: L("复制到剪贴板"), target: self, action: #selector(copyToPasteboard))
        copy.bezelStyle = .rounded
        copy.bezelColor = .systemBlue
        copy.contentTintColor = .white
        copy.wantsLayer = true
        copy.layer?.backgroundColor = NSColor.systemBlue.cgColor
        copy.layer?.cornerRadius = 6
        copy.frame = CGRect(x: 678, y: 18, width: 118, height: 32)
        content.addSubview(save)
        content.addSubview(copy)

        panel.contentView = content
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func save() {
        let dialog = NSSavePanel()
        dialog.allowedFileTypes = ["mp4"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        dialog.nameFieldStringValue = formatter.string(from: Date()) + ".mp4"
        dialog.beginSheetModal(for: panel!) { [weak self] response in
            guard let self, response == .OK, let target = dialog.url else { return }
            self.export(to: target) { result in
                switch result {
                case .success: self.close()
                case .failure(let error): self.showError(error)
                }
            }
        }
    }

    @objc private func copyToPasteboard() {
        let copiedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("superscreenshot-clip-\(UUID().uuidString).mp4")
        export(to: copiedURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let output):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([output as NSURL])
                self.close()
            case .failure(let error): self.showError(error)
            }
        }
    }

    private func export(to target: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: target) }
        // Keeping the entire recording must not introduce a second encode.
        // This preserves the original capture's exact dimensions and bitrate.
        if trimRangeView.start <= 0.001, trimRangeView.end >= duration - 0.001 {
            do {
                try FileManager.default.copyItem(at: url, to: target)
                completion(.success(target))
            } catch { completion(.failure(error)) }
            return
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(NSError(domain: "SuperScreenshot.Recording", code: 20, userInfo: [NSLocalizedDescriptionKey: L("无法创建视频导出器")])))
            return
        }
        exporter.outputURL = target
        exporter.outputFileType = .mp4
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: trimRangeView.start, preferredTimescale: 600),
            end: CMTime(seconds: trimRangeView.end, preferredTimescale: 600)
        )
        exporter.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed: completion(.success(target))
                default:
                    completion(.failure(exporter.error ?? NSError(domain: "SuperScreenshot.Recording", code: 21, userInfo: [NSLocalizedDescriptionKey: L("录屏导出失败")])))
                }
                _ = self
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("录屏导出失败")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("好"))
        alert.beginSheetModal(for: panel!)
    }

    private func close() { player.pause(); panel?.orderOut(nil); panel = nil }
}

@MainActor
private final class RecordingTrimRangeView: NSView {
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var start: Double = 0 { didSet { needsDisplay = true } }
    var end: Double = 1 { didSet { needsDisplay = true } }
    var onPreview: ((Double) -> Void)?
    private enum DragTarget { case start, end }
    private var dragTarget: DragTarget?

    override func draw(_ dirtyRect: NSRect) {
        let track = CGRect(x: 8, y: bounds.midY - 3, width: bounds.width - 16, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let startX = position(for: start)
        let endX = position(for: end)
        let selection = CGRect(x: startX, y: track.minY, width: max(1, endX - startX), height: track.height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: selection, xRadius: 3, yRadius: 3).fill()
        for x in [startX, endX] {
            let handle = CGRect(x: x - 7, y: bounds.midY - 11, width: 14, height: 22)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 7, yRadius: 7).fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let line = NSBezierPath(); line.move(to: CGPoint(x: x - 2, y: bounds.midY - 5)); line.line(to: CGPoint(x: x - 2, y: bounds.midY + 5)); line.move(to: CGPoint(x: x + 2, y: bounds.midY - 5)); line.line(to: CGPoint(x: x + 2, y: bounds.midY + 5)); line.lineWidth = 1; line.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        dragTarget = abs(x - position(for: start)) <= abs(x - position(for: end)) ? .start : .end
        update(at: x)
    }
    override func mouseDragged(with event: NSEvent) { update(at: convert(event.locationInWindow, from: nil).x) }
    override func mouseUp(with event: NSEvent) { dragTarget = nil }

    private func update(at x: CGFloat) {
        guard let dragTarget else { return }
        let value = max(0, min(duration, Double((x - 8) / max(1, bounds.width - 16)) * duration))
        let minimumLength = min(0.1, duration)
        switch dragTarget {
        case .start: start = min(value, end - minimumLength); onPreview?(start)
        case .end: end = max(value, start + minimumLength); onPreview?(end)
        }
    }

    private func position(for value: Double) -> CGFloat { 8 + CGFloat(value / max(duration, 0.001)) * (bounds.width - 16) }
}

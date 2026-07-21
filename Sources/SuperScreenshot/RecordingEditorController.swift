import AppKit
import AVFoundation
import AVKit

@MainActor
final class RecordingEditorController: NSObject {
    private let url: URL
    private let asset: AVURLAsset
    private let player: AVPlayer
    private var panel: NSPanel?
    private var startSlider: NSSlider!
    private var endSlider: NSSlider!
    private let rangeLabel = NSTextField(labelWithString: "")
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
        preview.controlsStyle = .floating
        preview.videoGravity = .resizeAspect
        content.addSubview(preview)

        let caption = NSTextField(labelWithString: L("拖动起点和终点，选择需要保留的录屏片段"))
        caption.font = .systemFont(ofSize: 13)
        caption.textColor = .secondaryLabelColor
        caption.frame = CGRect(x: 32, y: 126, width: 560, height: 20)
        content.addSubview(caption)

        startSlider = NSSlider(value: 0, minValue: 0, maxValue: duration, target: self, action: #selector(rangeChanged))
        startSlider.frame = CGRect(x: 32, y: 93, width: 650, height: 22)
        endSlider = NSSlider(value: duration, minValue: 0, maxValue: duration, target: self, action: #selector(rangeChanged))
        endSlider.frame = CGRect(x: 32, y: 66, width: 650, height: 22)
        content.addSubview(startSlider)
        content.addSubview(endSlider)

        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        rangeLabel.alignment = .right
        rangeLabel.frame = CGRect(x: 690, y: 78, width: 106, height: 22)
        content.addSubview(rangeLabel)
        updateRangeLabel()

        let copy = NSButton(title: L("复制到剪贴板"), target: self, action: #selector(copyToPasteboard))
        copy.bezelStyle = .rounded
        copy.frame = CGRect(x: 558, y: 18, width: 118, height: 32)
        let save = NSButton(title: L("保存"), target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = CGRect(x: 688, y: 18, width: 108, height: 32)
        content.addSubview(copy)
        content.addSubview(save)

        panel.contentView = content
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func rangeChanged(_ sender: NSSlider) {
        let minimumLength = min(0.1, duration)
        if sender === startSlider, startSlider.doubleValue > endSlider.doubleValue - minimumLength {
            endSlider.doubleValue = min(duration, startSlider.doubleValue + minimumLength)
        } else if sender === endSlider, endSlider.doubleValue < startSlider.doubleValue + minimumLength {
            startSlider.doubleValue = max(0, endSlider.doubleValue - minimumLength)
        }
        player.seek(to: CMTime(seconds: startSlider.doubleValue, preferredTimescale: 600))
        updateRangeLabel()
    }

    private func updateRangeLabel() {
        rangeLabel.stringValue = "(timeText(startSlider.doubleValue)) – (timeText(endSlider.doubleValue))"
    }

    private func timeText(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    @objc private func save() {
        let dialog = NSSavePanel()
        dialog.allowedFileTypes = ["mp4"]
        dialog.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".mp4"
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
            .appendingPathComponent("superscreenshot-clip-(UUID().uuidString).mp4")
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
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(NSError(domain: "SuperScreenshot.Recording", code: 20, userInfo: [NSLocalizedDescriptionKey: L("无法创建视频导出器")])))
            return
        }
        exporter.outputURL = target
        exporter.outputFileType = .mp4
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: startSlider.doubleValue, preferredTimescale: 600),
            end: CMTime(seconds: endSlider.doubleValue, preferredTimescale: 600)
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

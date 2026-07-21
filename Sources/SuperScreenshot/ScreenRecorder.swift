import AVFoundation
@preconcurrency import ScreenCaptureKit

enum RecordingFrameRate: Int, CaseIterable {
    case low = 30
    case standard = 60
    case high = 120
}

@available(macOS 13.0, *)
private final class RecordingWriterPipeline: @unchecked Sendable {
    enum FinishResult: Sendable {
        case success
        case failure(String)
    }

    let queue = DispatchQueue(label: "com.lion.superscreenshot.record.writer")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var errorDescription: String?

    func prepare(url: URL, width: Int, height: Int, includesAudio: Bool) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        self.writer = writer
        videoInput = video
        if includesAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            audioInput = audio
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer else { return }
        if !started, type == .screen {
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = writer.status == .writing
        }
        guard writer.status == .writing else { return }
        let accepted: Bool
        switch type {
        case .screen where videoInput?.isReadyForMoreMediaData == true:
            accepted = videoInput?.append(sampleBuffer) ?? false
        case .audio where audioInput?.isReadyForMoreMediaData == true:
            accepted = audioInput?.append(sampleBuffer) ?? false
        default:
            return
        }
        if !accepted {
            errorDescription = writer.error?.localizedDescription
        }
    }

    func finish() async -> FinishResult {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let writer = self.writer, self.started, writer.status == .writing else {
                    let detail = self.errorDescription ?? self.writer?.error?.localizedDescription ?? "没有收到可写入的视频帧"
                    continuation.resume(returning: .failure(detail))
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: .success)
                    } else {
                        continuation.resume(returning: .failure(writer.error?.localizedDescription ?? "视频文件收尾失败"))
                    }
                }
            }
        }
    }
}

struct ScreenRecordingOptions {
    var frameRate: RecordingFrameRate = .standard
    var capturesSystemAudio = false
}

@available(macOS 13.0, *)
extension ScreenRecorder {
    static func supportedFrameRates(for screen: NSScreen) -> [RecordingFrameRate] {
        let refreshRate = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenRefreshRate")] as? NSNumber)?.doubleValue ?? 60
        return refreshRate >= 119 ? RecordingFrameRate.allCases : [.low, .standard]
    }
}

@available(macOS 13.0, *)
@MainActor
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isRecording = false
    private(set) var lastErrorDescription: String?
    private var stream: SCStream?
    private var outputURL: URL?
    private var options = ScreenRecordingOptions()
    private let writerPipeline = RecordingWriterPipeline()

    func start(screen: NSScreen, selection: CGRect? = nil, options: ScreenRecordingOptions, outputURL: URL) async throws {
        guard !isRecording,
              let displayID = ScreenCapture.displayID(for: screen) else { return }
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        configuration.width = max(1, Int(screen.frame.width * scale))
        configuration.height = max(1, Int(screen.frame.height * scale))
        if let selection {
            configuration.sourceRect = CGRect(x: (selection.minX - screen.frame.minX) * scale,
                                              y: (screen.frame.maxY - selection.maxY) * scale,
                                              width: selection.width * scale,
                                              height: selection.height * scale)
            configuration.width = max(1, Int((selection.width * scale).rounded()))
            configuration.height = max(1, Int((selection.height * scale).rounded()))
        }
        // H.264/HEVC encoders require even pixel dimensions. Selection edges
        // can otherwise produce an MP4 with media data but no valid moov atom.
        configuration.width = max(2, configuration.width & ~1)
        configuration.height = max(2, configuration.height & ~1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate.rawValue))
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        self.options = options
        self.outputURL = outputURL
        try writerPipeline.prepare(url: outputURL, width: configuration.width, height: configuration.height, includesAudio: options.capturesSystemAudio)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerPipeline.queue)
        if options.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerPipeline.queue)
        }
        try await stream.startCapture()
        self.stream = stream
        isRecording = true
    }

    func stop() async throws -> URL? {
        guard isRecording else { return outputURL }
        try await stream?.stopCapture()
        isRecording = false
        stream = nil
        switch await writerPipeline.finish() {
        case .success:
            return outputURL
        case .failure(let description):
            lastErrorDescription = description
            return nil
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        writerPipeline.append(sampleBuffer, type: type)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Keep the recorder in the stopping state so the user's stop action
        // can still finalize the writer and produce a playable MP4.
        print("Screen recording stream stopped: \(error)")
    }
}

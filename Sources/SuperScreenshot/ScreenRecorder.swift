import AVFoundation
@preconcurrency import ScreenCaptureKit

enum RecordingFrameRate: Int, CaseIterable {
    case low = 30
    case standard = 60
    case high = 120
}

private final class SampleBufferBox: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
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
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var options = ScreenRecordingOptions()

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
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        self.writer = writer
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        videoInput = video
        if options.capturesSystemAudio {
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
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.lion.superscreenshot.record.video"))
        if options.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.lion.superscreenshot.record.audio"))
        }
        try await stream.startCapture()
        self.stream = stream
        isRecording = true
    }

    func stop() async throws -> URL? {
        guard isRecording else { return outputURL }
        try await stream?.stopCapture()
        // ScreenCaptureKit can still have samples queued on its output queues.
        // Wait briefly for the first sample to start the writer before finalizing.
        for _ in 0..<20 where writer?.status == .unknown {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard writer?.status == .writing else {
            writer?.cancelWriting()
            isRecording = false
            stream = nil
            return nil
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if let writer {
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }
        isRecording = false
        stream = nil
        return writer?.status == .completed ? outputURL : nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let boxed = SampleBufferBox(sampleBuffer)
        Task { @MainActor [weak self] in
            let sampleBuffer = boxed.value
            guard let self, CMSampleBufferDataIsReady(sampleBuffer) else { return }
            if writer?.status == .unknown { writer?.startWriting(); writer?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp) }
            guard writer?.status == .writing else { return }
            switch type {
            case .screen where videoInput?.isReadyForMoreMediaData == true:
                videoInput?.append(sampleBuffer)
            case .audio where audioInput?.isReadyForMoreMediaData == true:
                audioInput?.append(sampleBuffer)
            default: break
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Keep the recorder in the stopping state so the user's stop action
        // can still finalize the writer and produce a playable MP4.
        print("Screen recording stream stopped: \(error)")
    }
}

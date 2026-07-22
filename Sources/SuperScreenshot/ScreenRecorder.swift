import AVFoundation
import VideoToolbox
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
    private var compressionSession: VTCompressionSession?
    private let writerLock = NSLock()
    private var started = false
    private var errorDescription: String?

    func prepare(url: URL, width: Int, height: Int, frameRate: Int, bitRate: Int, includesAudio: Bool) throws {
        // The recorder instance is reused for later recordings. Do not carry
        // a completed writer's state into the next session.
        writer = nil
        videoInput = nil
        audioInput = nil
        compressionSession = nil
        started = false
        errorDescription = nil

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        // VideoToolbox produces H.264 sample buffers directly. Giving the
        // writer a nil output setting prevents it from creating a second,
        // opaque compression session that filters encoder properties.
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        self.writer = writer
        videoInput = video
        try configureCompressionSession(width: width, height: height, frameRate: frameRate, bitRate: bitRate)
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

    private func configureCompressionSession(width: Int, height: Int, frameRate: Int, bitRate: Int) throws {
        var session: VTCompressionSession?
        let attributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let createStatus = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attributes,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard createStatus == noErr, let session else {
            throw NSError(domain: "SuperScreenshot.Recording", code: Int(createStatus), userInfo: [NSLocalizedDescriptionKey: "无法创建 H.264 编码器"])
        }

        try setRequired(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        try setRequired(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitRate))
        try setRequired(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: frameRate))
        try setRequired(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: frameRate))
        try setRequired(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        try setRequired(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        try setRequired(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)

        // Optional hardware-specific quality controls. They are deliberately
        // applied here, rather than through AVAssetWriter, so unsupported
        // keys can be ignored without changing the recording's validity.
        setOptional(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: 0.9))
        setOptional(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse)
        setOptional(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: NSNumber(value: 28))
        if #available(macOS 15.0, *) {
            setOptional(session, key: kVTCompressionPropertyKey_SpatialAdaptiveQPLevel, value: NSNumber(value: 1))
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            throw NSError(domain: "SuperScreenshot.Recording", code: Int(prepareStatus), userInfo: [NSLocalizedDescriptionKey: "无法初始化 H.264 编码器"])
        }
        compressionSession = session
    }

    private func setRequired(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw NSError(domain: "SuperScreenshot.Recording", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法设置 H.264 编码参数"])
        }
    }

    private func setOptional(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) {
        _ = VTSessionSetProperty(session, key: key, value: value)
    }

    private static let compressionOutputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon else { return }
        let pipeline = Unmanaged<RecordingWriterPipeline>.fromOpaque(refcon).takeUnretainedValue()
        pipeline.appendCompressedSample(sampleBuffer, status: status)
    }

    private func appendCompressedSample(_ sampleBuffer: CMSampleBuffer?, status: OSStatus) {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer), let writer else {
            if status != noErr { errorDescription = "H.264 编码失败 (\(status))" }
            return
        }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = writer.status == .writing
        }
        guard writer.status == .writing, videoInput?.isReadyForMoreMediaData == true else { return }
        if videoInput?.append(sampleBuffer) != true {
            errorDescription = writer.error?.localizedDescription ?? "H.264 编码帧写入失败"
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let compressionSession else {
                errorDescription = "录屏帧不包含图像数据"
                return
            }
            let status = VTCompressionSessionEncodeFrame(
                compressionSession,
                imageBuffer: imageBuffer,
                presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                duration: CMSampleBufferGetDuration(sampleBuffer),
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            if status != noErr {
                errorDescription = "H.264 编码器拒绝了屏幕帧 (\(status))"
            }
        case .audio:
            writerLock.lock()
            defer { writerLock.unlock() }
            guard let writer, writer.status == .writing, audioInput?.isReadyForMoreMediaData == true else { return }
            let accepted = audioInput?.append(sampleBuffer) ?? false
            if !accepted {
                errorDescription = writer.error?.localizedDescription ?? "音频编码器拒绝了音频帧"
            }
        default:
            return
        }
    }

    func finish() async -> FinishResult {
        await withCheckedContinuation { continuation in
            queue.async {
                if let compressionSession = self.compressionSession {
                    VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
                    VTCompressionSessionInvalidate(compressionSession)
                    self.compressionSession = nil
                }
                self.writerLock.lock()
                defer { self.writerLock.unlock() }
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
    var bitRate = 1_000_000
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
        // ScreenCaptureKit uses the display's capture pixel grid, which is not
        // necessarily NSScreen.backingScaleFactor on scaled Retina displays.
        let xScale = CGFloat(display.width) / screen.frame.width
        let yScale = CGFloat(display.height) / screen.frame.height
        configuration.width = max(1, Int((screen.frame.width * xScale).rounded()))
        configuration.height = max(1, Int((screen.frame.height * yScale).rounded()))
        if let selection {
            let displayRect = CGRect(x: 0, y: 0, width: display.width, height: display.height)
            let requestedRect = CGRect(x: (selection.minX - screen.frame.minX) * xScale,
                                       y: (screen.frame.maxY - selection.maxY) * yScale,
                                       width: selection.width * xScale,
                                       height: selection.height * yScale)
            let sourceRect = requestedRect.integral.intersection(displayRect)
            guard sourceRect.width >= 2, sourceRect.height >= 2 else {
                throw NSError(domain: "SuperScreenshot.Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: "录制区域超出当前屏幕范围"])
            }
            configuration.sourceRect = sourceRect
            configuration.width = Int(sourceRect.width)
            configuration.height = Int(sourceRect.height)
        }
        // H.264/HEVC encoders require even pixel dimensions. Selection edges
        // can otherwise produce an MP4 with media data but no valid moov atom.
        configuration.width = max(2, configuration.width & ~1)
        configuration.height = max(2, configuration.height & ~1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate.rawValue))
        configuration.queueDepth = 5
        // Feed the writer a stable, explicitly declared pixel format instead
        // of relying on the screen server's dynamic raw frame format.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Record SDR in one known color space. Without this, ScreenCaptureKit
        // may deliver display-profile colors that an H.264 player interprets
        // as a different range, producing the dark/desaturated result.
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        self.options = options
        self.outputURL = outputURL
        try writerPipeline.prepare(url: outputURL, width: configuration.width, height: configuration.height, frameRate: options.frameRate.rawValue, bitRate: options.bitRate, includesAudio: options.capturesSystemAudio)
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

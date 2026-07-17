import AppKit
import CoreGraphics

enum LongCaptureError: LocalizedError {
    case captureFailed, notEnoughFrames, stitchFailed
    var errorDescription: String? {
        switch self {
        case .captureFailed: return L("无法读取屏幕内容。")
        case .notEnoughFrames: return L("没有检测到可滚动内容。")
        case .stitchFailed: return L("长截图拼接失败。")
        }
    }
}

final class LongCaptureEngine: @unchecked Sendable {
    func capture(
        session: ScreenCaptureSession,
        control: LongCaptureControl,
        onPreviewUpdated: @escaping @Sendable (CGImage) -> Void
    ) async throws -> CGImage {
        let initial = try await session.capture()
        var frames: [CGImage] = [initial]
        var motions: [EdgeMotion] = []
        onPreviewUpdated(initial)
        var candidate: CGImage?
        var candidateMotion: EdgeMotion?
        var candidateStableSamples = 0

        while true {
            switch await control.state {
            case .cancelled:
                throw CancellationError()
            case .finished:
                if let candidate, let candidateMotion {
                    frames.append(candidate)
                    motions.append(candidateMotion)
                    onPreviewUpdated(ImageStitcher.stitch(frames, motions: motions) ?? candidate)
                }
                if frames.count == 1 { return frames[0] }
                return ImageStitcher.stitch(frames, motions: motions) ?? frames[0]
            case .running:
                break
            }

            try await Task.sleep(nanoseconds: 16_000_000)
            let current = try await session.capture()
            if ImageStitcher.isNearlyIdentical(frames.last!, current) {
                candidate = nil; candidateMotion = nil; candidateStableSamples = 0
                continue
            }
            guard let motion = ImageStitcher.detectEdgeMotion(previous: frames.last!, next: current) else {
                candidate = nil; candidateMotion = nil; candidateStableSamples = 0
                continue
            }
            if let pending = candidate,
               candidateMotion?.direction == motion.direction,
               ImageStitcher.relevantEdgeIsStable(pending, current, direction: motion.direction) {
                candidateStableSamples += 1
                if candidateStableSamples >= 1 {
                    frames.append(current)
                    motions.append(motion)
                    onPreviewUpdated(ImageStitcher.stitch(frames, motions: motions) ?? current)
                    candidate = nil; candidateMotion = nil; candidateStableSamples = 0
                    if frames.count >= 120 {
                        return ImageStitcher.stitch(frames, motions: motions) ?? frames[0]
                    }
                }
            } else {
                candidate = current
                candidateMotion = motion
                candidateStableSamples = 0
            }
        }
    }
}

actor LongCaptureControl {
    enum State { case running, finished, cancelled }
    private(set) var state: State = .running
    func finish() { state = .finished }
    func cancel() { state = .cancelled }
}

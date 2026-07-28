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
    static func isPlausibleAutomaticMotion(
        _ motion: EdgeMotion,
        expectedShift: Int,
        maximumShift: Int
    ) -> Bool {
        // An automatic step is deliberately large: retain only a narrow bottom
        // overlap, then stitch once.  Constrain the detected result around the
        // requested displacement so a repeated row cannot be mistaken for a
        // distant match and silently drop content.
        let tolerance = max(24, expectedShift / 20)
        return motion.direction == .contentMovesUp
            && motion.shift <= maximumShift
            && abs(motion.shift - expectedShift) <= tolerance
    }

    func capture(
        session: ScreenCaptureSession,
        control: LongCaptureControl,
        automaticExpectedShift: Int,
        onAutoScrollStep: @escaping @Sendable () async -> Void,
        onPreviewUpdated: @escaping @Sendable (CGImage) async -> Void
    ) async throws -> CGImage {
        let initial = try await session.capture()
        var frames: [CGImage] = [initial]
        var motions: [EdgeMotion] = []
        CaptureDiagnostics.longCapture(
            "start source=\(session.sourceRect.debugDescription) scale=\(session.scale) frame=\(initial.width)x\(initial.height)"
        )
        await onPreviewUpdated(initial)
        var candidate: CGImage?
        var candidateMotion: EdgeMotion?
        var candidateStableSamples = 0
        var waitingForAutomaticFrame = false
        var automaticPulseTime: TimeInterval?

        while true {
            let status = await control.status
            switch status.state {
            case .cancelled:
                throw CancellationError()
            case .finished:
                if let candidate, let candidateMotion {
                    frames.append(candidate)
                    motions.append(candidateMotion)
                    await onPreviewUpdated(ImageStitcher.stitch(frames, motions: motions) ?? candidate)
                }
                if frames.count == 1 { return frames[0] }
                return ImageStitcher.stitch(frames, motions: motions) ?? frames[0]
            case .running:
                break
            }

            if status.isAutoScrolling {
                let now = ProcessInfo.processInfo.systemUptime
                let needsRetry = automaticPulseTime.map { now - $0 >= 0.4 } ?? false
                if !waitingForAutomaticFrame || needsRetry {
                    await onAutoScrollStep()
                    waitingForAutomaticFrame = true
                    automaticPulseTime = ProcessInfo.processInfo.systemUptime
                }
            } else {
                waitingForAutomaticFrame = false
                automaticPulseTime = nil
            }

            // The wheel pulse animation completes before this point.  Do not
            // sample its intermediate compositor state: a large automatic step
            // must settle fully before its only candidate frame is evaluated.
            let captureDelay: UInt64 = status.isAutoScrolling ? 120_000_000 : 16_000_000
            try await Task.sleep(nanoseconds: captureDelay)
            let current = try await session.capture()
            if ImageStitcher.isNearlyIdentical(frames.last!, current) {
                candidate = nil; candidateMotion = nil; candidateStableSamples = 0
                continue
            }
            let detectedMotion = status.isAutoScrolling
                ? ImageStitcher.detectAutomaticMotion(
                    previous: frames.last!,
                    next: current,
                    expectedShift: automaticExpectedShift
                )
                : ImageStitcher.detectEdgeMotion(previous: frames.last!, next: current)
            guard let motion = detectedMotion else {
                if candidate != nil {
                    CaptureDiagnostics.longCapture("discard pending frame: no reliable motion")
                }
                candidate = nil; candidateMotion = nil; candidateStableSamples = 0
                continue
            }
            // Automatic scrolling always moves the page content upward. Reject
            // ambiguous reverse matches and implausibly large jumps instead of
            // inserting them at the beginning of the stitched document.
            if status.isAutoScrolling,
               !Self.isPlausibleAutomaticMotion(
                    motion,
                    expectedShift: automaticExpectedShift,
                    maximumShift: frames.last!.height - 20
               ) {
                CaptureDiagnostics.longCapture(
                    "reject automatic motion direction=\(motion.direction) shift=\(motion.shift) score=\(motion.score)"
                )
                candidate = nil; candidateMotion = nil; candidateStableSamples = 0
                continue
            }
            if status.isAutoScrolling {
                frames.append(current)
                motions.append(motion)
                CaptureDiagnostics.longCapture(
                    "accept automatic frame=\(frames.count - 1) size=\(current.width)x\(current.height) shift=\(motion.shift) score=\(motion.score)"
                )
                // This is the commit barrier for automatic capture.  Build and
                // display the new stitched preview before allowing the next
                // wheel step; otherwise a busy UI can look as if it skipped a
                // frame and a delayed compositor update can be captured next.
                await onPreviewUpdated(ImageStitcher.preview(frames, motions: motions) ?? current)
                await Task.yield()
                candidate = nil; candidateMotion = nil; candidateStableSamples = 0
                waitingForAutomaticFrame = false
                automaticPulseTime = nil
                continue
            }
            if let pending = candidate,
               candidateMotion?.direction == motion.direction,
               abs((candidateMotion?.shift ?? motion.shift) - motion.shift) <= 1,
               ImageStitcher.relevantEdgeIsStable(pending, current, direction: motion.direction) {
                candidateStableSamples += 1
                if candidateStableSamples >= 1 {
                    frames.append(current)
                    motions.append(motion)
                    CaptureDiagnostics.longCapture(
                        "accept manual frame=\(frames.count - 1) size=\(current.width)x\(current.height) shift=\(motion.shift) score=\(motion.score) neighbours=\(ImageStitcher.manualMotionDiagnostics(previous: frames[frames.count - 2], next: current, motion: motion))"
                    )
                    await onPreviewUpdated(ImageStitcher.preview(frames, motions: motions) ?? current)
                    candidate = nil; candidateMotion = nil; candidateStableSamples = 0
                    waitingForAutomaticFrame = false
                    automaticPulseTime = nil
                }
            } else {
                if let pendingMotion = candidateMotion,
                   (pendingMotion.direction != motion.direction || abs(pendingMotion.shift - motion.shift) > 1) {
                    CaptureDiagnostics.longCapture(
                        "replace pending motion old=\(pendingMotion.direction)/\(pendingMotion.shift)/\(pendingMotion.score) new=\(motion.direction)/\(motion.shift)/\(motion.score)"
                    )
                }
                candidate = current
                candidateMotion = motion
                candidateStableSamples = 0
            }
        }
    }
}

actor LongCaptureControl {
    enum State { case running, finished, cancelled }
    struct Status: Sendable {
        let state: State
        let isAutoScrolling: Bool
    }
    private(set) var state: State = .running
    private var isAutoScrolling = false
    var status: Status { Status(state: state, isAutoScrolling: isAutoScrolling) }
    func finish() { state = .finished }
    func cancel() { state = .cancelled }
    func setAutoScrolling(_ enabled: Bool) { isAutoScrolling = enabled }
}

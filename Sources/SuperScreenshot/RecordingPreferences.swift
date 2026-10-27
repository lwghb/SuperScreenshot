import Foundation
import CoreGraphics

/// User preferences are kept separately from the effective options for one screen/region.
struct RecordingPreferences {
    var frameRate: RecordingFrameRate = .standard
    var bitRateMbps: Double = 1
    var capturesSystemAudio = false

    init(defaults: UserDefaults = .standard) {
        frameRate = RecordingFrameRate(rawValue: defaults.integer(forKey: "recording.frameRate")) ?? .standard
        let saved = defaults.double(forKey: "recording.bitRateMbps")
        bitRateMbps = saved.isFinite && saved >= 1 ? min(saved, 60) : 1
        capturesSystemAudio = defaults.bool(forKey: "recording.capturesSystemAudio")
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(frameRate.rawValue, forKey: "recording.frameRate")
        defaults.set(bitRateMbps, forKey: "recording.bitRateMbps")
        defaults.set(capturesSystemAudio, forKey: "recording.capturesSystemAudio")
    }

    func effectiveFrameRate(supportsHighFrameRate: Bool) -> RecordingFrameRate {
        frameRate == .high && !supportsHighFrameRate ? .standard : frameRate
    }

    static func maximumBitRateMbps(pixelSize: CGSize, frameRate: RecordingFrameRate) -> Double {
        let calculated = Double(pixelSize.width * pixelSize.height) * Double(frameRate.rawValue) * 0.28 / 1_000_000
        return min(60, max(1, (calculated * 10).rounded(.up) / 10))
    }

    func effectiveBitRateMbps(pixelSize: CGSize, supportsHighFrameRate: Bool) -> Double {
        min(max(bitRateMbps, 1), Self.maximumBitRateMbps(pixelSize: pixelSize, frameRate: effectiveFrameRate(supportsHighFrameRate: supportsHighFrameRate)))
    }
}

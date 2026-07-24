import Foundation
import OSLog
import CoreGraphics

/// Narrow diagnostics for a user-reported long-capture seam.  These entries
/// are intentionally kept in the unified log so they don't create user files
/// or affect the capture hot path.
enum CaptureDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.lion.superscreenshot.screenkit",
        category: "LongCapture"
    )

    static func longCapture(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func selection(_ message: String) {
        logger.notice("selection \(message, privacy: .public)")
    }
}

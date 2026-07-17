import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case displayNotFound
    case captureFailed
    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "没有找到要截图的显示器。"
        case .captureFailed: return "系统未能读取屏幕内容，请检查屏幕录制权限。"
        }
    }
}

struct ScreenCaptureSession: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let scale: CGFloat

    func capture() async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await captureWithScreenCaptureKit()
        }
        guard let image = CGDisplayCreateImage(displayID, rect: sourceRect) else {
            throw ScreenCaptureError.captureFailed
        }
        return image
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit() async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        let pixelSize = ScreenCapture.pixelSize(for: sourceRect, scale: scale)
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

enum ScreenCapture {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
    static func displayRect(for rect: CGRect, on screen: NSScreen) -> CGRect {
        displayRect(for: rect, screenFrame: screen.frame)
    }
    static func displayRect(for rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height).integral
    }
    static func pixelSize(for sourceRect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (
            width: max(1, Int((sourceRect.width * scale).rounded(.up))),
            height: max(1, Int((sourceRect.height * scale).rounded(.up)))
        )
    }
    static func verifyAccess() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.captureFailed }
    }
    static func makeSession(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        scale: CGFloat
    ) async throws -> ScreenCaptureSession {
        ScreenCaptureSession(
            displayID: displayID,
            sourceRect: sourceRect,
            scale: scale
        )
    }
}

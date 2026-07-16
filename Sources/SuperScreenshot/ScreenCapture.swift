import AppKit
import CoreGraphics

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

    func capture() async throws -> CGImage {
        guard let image = CGDisplayCreateImage(displayID, rect: sourceRect) else {
            throw ScreenCaptureError.captureFailed
        }
        return image
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
            sourceRect: sourceRect
        )
    }
}

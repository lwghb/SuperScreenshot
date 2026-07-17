import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case displayNotFound
    case captureFailed
    var errorDescription: String? {
        switch self {
        case .displayNotFound: return L("没有找到要截图的显示器。")
        case .captureFailed: return L("系统未能读取屏幕内容，请检查屏幕录制权限。")
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
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
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
    static func displaySnapshot(for screen: NSScreen) -> CGImage? {
        guard CGPreflightScreenCaptureAccess(), let displayID = displayID(for: screen) else { return nil }
        return CGDisplayCreateImage(displayID)
    }

    static func crop(_ snapshot: CGImage, to rect: CGRect, on screen: NSScreen) -> CGImage? {
        crop(snapshot, to: rect, on: screen.frame)
    }

    static func crop(_ snapshot: CGImage, to rect: CGRect, on screenFrame: CGRect) -> CGImage? {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let sourceRect = displayRect(for: rect, screenFrame: screenFrame)
        let scaleX = CGFloat(snapshot.width) / screenFrame.width
        let scaleY = CGFloat(snapshot.height) / screenFrame.height
        let pixelRect = CGRect(
            x: sourceRect.minX * scaleX,
            y: sourceRect.minY * scaleY,
            width: sourceRect.width * scaleX,
            height: sourceRect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0 else { return nil }
        return snapshot.cropping(to: pixelRect)
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
    static func displayRect(for rect: CGRect, on screen: NSScreen) -> CGRect {
        displayRect(for: rect, screenFrame: screen.frame, scale: screen.backingScaleFactor)
    }
    static func displayRect(for rect: CGRect, screenFrame: CGRect, scale: CGFloat = 1) -> CGRect {
        pixelAligned(
            CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY,
                   width: rect.width, height: rect.height),
            scale: scale
        )
    }
    static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(1, scale)
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
    static func pixelSize(for sourceRect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (
            width: max(1, Int((sourceRect.width * scale).rounded())),
            height: max(1, Int((sourceRect.height * scale).rounded()))
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

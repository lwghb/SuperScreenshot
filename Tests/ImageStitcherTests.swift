import CoreGraphics
import Testing
@testable import SuperScreenshot

struct ImageStitcherTests {
    @Test func convertsAppKitSelectionToDisplayCoordinates() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 100, y: 200, width: 300, height: 400)
        let result = ScreenCapture.displayRect(for: selection, screenFrame: screen)
        #expect(result == CGRect(x: 100, y: 300, width: 300, height: 400))
    }

    @Test func convertsSelectionOnOffsetDisplay() {
        let screen = CGRect(x: -1280, y: 120, width: 1280, height: 800)
        let selection = CGRect(x: -1180, y: 220, width: 240, height: 300)
        let result = ScreenCapture.displayRect(for: selection, screenFrame: screen)
        #expect(result == CGRect(x: 100, y: 400, width: 240, height: 300))
    }

    @Test func scalesCaptureToRetinaPixels() {
        let size = ScreenCapture.pixelSize(
            for: CGRect(x: 20, y: 30, width: 320, height: 180),
            scale: 2
        )
        #expect(size.width == 640)
        #expect(size.height == 360)
    }

    @Test func alignsSelectionAndCaptureToSameRetinaPixels() {
        let selection = CGRect(x: 100.24, y: 200.26, width: 300.51, height: 180.49)
        let aligned = ScreenCapture.pixelAligned(selection, scale: 2)
        let capture = ScreenCapture.displayRect(
            for: aligned,
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            scale: 2
        )
        #expect((aligned.minX * 2).rounded() == aligned.minX * 2)
        #expect((aligned.minY * 2).rounded() == aligned.minY * 2)
        #expect(ScreenCapture.pixelSize(for: capture, scale: 2).width == Int(aligned.width * 2))
        #expect(ScreenCapture.pixelSize(for: capture, scale: 2).height == Int(aligned.height * 2))
    }

    @Test func expandsFractionalSelectionToWholeBackingPixels() {
        let aligned = ScreenCapture.pixelAligned(
            CGRect(x: 100.24, y: 200.26, width: 300.51, height: 180.49),
            scale: 2
        )
        #expect(aligned.minX == 100)
        #expect(aligned.minY == 200)
        #expect(aligned.maxX == 401)
        #expect(aligned.maxY == 381)
    }

    @Test func preservesRetinaEdgesAfterDisplayCoordinateConversion() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let selection = CGRect(x: 358.5, y: 312.5, width: 920, height: 656.5)
        let capture = ScreenCapture.displayRect(for: selection, screenFrame: screen, scale: 2)
        #expect(capture == CGRect(x: 358.5, y: 148, width: 920, height: 656.5))
        #expect(ScreenCapture.pixelSize(for: capture, scale: 2).width == 1840)
        #expect(ScreenCapture.pixelSize(for: capture, scale: 2).height == 1313)
    }

    @Test func cropsAdjustedSelectionAtDisplayPixelScale() throws {
        let context = try #require(CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let snapshot = try #require(context.makeImage())
        let cropped = try #require(ScreenCapture.crop(
            snapshot,
            to: CGRect(x: 10, y: 5, width: 20, height: 15),
            on: CGRect(x: 0, y: 0, width: 100, height: 50)
        ))
        #expect(cropped.width == 40)
        #expect(cropped.height == 30)
    }

    @Test func cropsHalfPointRetinaSelectionWithoutExpandingIt() throws {
        let context = try #require(CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let snapshot = try #require(context.makeImage())
        let cropped = try #require(ScreenCapture.crop(
            snapshot,
            to: CGRect(x: 10, y: 5, width: 20.5, height: 15.5),
            on: CGRect(x: 0, y: 0, width: 100, height: 50)
        ))
        #expect(cropped.width == 41)
        #expect(cropped.height == 31)
    }

    @Test func detectsEqualImages() throws {
        let ctx = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try #require(ctx.makeImage())
        #expect(ImageStitcher.isNearlyIdentical(image, image))
    }

    @Test func detectsScrolledContentChange() throws {
        let first = try #require(makeStripedImage(offset: 0))
        let second = try #require(makeStripedImage(offset: 13))
        #expect(!ImageStitcher.isNearlyIdentical(first, second))
        let stitched = try #require(ImageStitcher.stitch([first, second]))
        #expect(stitched.height > first.height)
    }

    @Test func detectsBothScrollDirections() throws {
        let document = try #require(makeDirectionalDocument())
        let upper = try #require(document.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 400)))
        let lower = try #require(document.cropping(to: CGRect(x: 0, y: 80, width: 160, height: 400)))
        let forward = ImageStitcher.bestMatch(previous: upper, next: lower)
        let backward = ImageStitcher.bestMatch(previous: lower, next: upper)
        #expect(forward.direction != backward.direction)
        #expect(abs(forward.overlap - backward.overlap) < 12)
        let forwardEdge = try #require(ImageStitcher.detectEdgeMotion(previous: upper, next: lower))
        let backwardEdge = try #require(ImageStitcher.detectEdgeMotion(previous: lower, next: upper))
        #expect(forwardEdge.direction != backwardEdge.direction)
        #expect(forwardEdge.shift == 80)
        #expect(backwardEdge.shift == 80)
    }

    @Test func automaticMotionUsesInteriorConsensus() throws {
        let document = try #require(makeDirectionalDocument())
        let upper = try #require(document.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 400)))
        let lower = try #require(document.cropping(to: CGRect(x: 0, y: 80, width: 160, height: 400)))
        let first = try #require(addFixedOverlay(to: upper))
        let second = try #require(addFixedOverlay(to: lower))
        let motion = try #require(ImageStitcher.detectAutomaticMotion(previous: first, next: second))
        #expect(motion.direction == .contentMovesUp)
        #expect(abs(motion.shift - 80) <= 1)
    }

    @Test func rejectsWrongOrExcessiveAutomaticScrollMotion() {
        #expect(LongCaptureEngine.isPlausibleAutomaticMotion(
            EdgeMotion(direction: .contentMovesUp, shift: 40, score: 0)
        ))
        #expect(!LongCaptureEngine.isPlausibleAutomaticMotion(
            EdgeMotion(direction: .contentMovesDown, shift: 40, score: 0)
        ))
        #expect(!LongCaptureEngine.isPlausibleAutomaticMotion(
            EdgeMotion(direction: .contentMovesUp, shift: 300, score: 0)
        ))
        #expect(LongCaptureEngine.isPlausibleAutomaticMotion(
            EdgeMotion(direction: .contentMovesUp, shift: 160, score: 0)
        ))
        #expect(!LongCaptureEngine.isPlausibleAutomaticMotion(
            EdgeMotion(direction: .contentMovesUp, shift: 320, score: 0)
        ))
        #expect(!LongCaptureEngine.isPlausibleAutomaticMotion(
            EdgeMotion(direction: .contentMovesDown, shift: 320, score: 0)
        ))
    }

    @Test func previewPreservesEveryAcceptedSliceAtFixedWidth() throws {
        let document = try #require(makeDirectionalDocument())
        let upper = try #require(document.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 400)))
        let lower = try #require(document.cropping(to: CGRect(x: 0, y: 80, width: 160, height: 400)))
        let motion = try #require(ImageStitcher.detectEdgeMotion(previous: upper, next: lower))
        let preview = try #require(ImageStitcher.preview(
            [upper, lower],
            motions: [motion],
            maximumWidth: 80
        ))
        #expect(preview.width == 80)
        #expect(preview.height == 240)
    }

    @Test func ignoresAnimationAwayFromCaptureEdges() throws {
        let first = try #require(makeInteriorAnimationImage(centerGray: 0.2))
        let second = try #require(makeInteriorAnimationImage(centerGray: 0.8))
        #expect(!ImageStitcher.relevantEdgeChanged(
            previous: first,
            next: second,
            direction: .contentMovesUp
        ))
        #expect(!ImageStitcher.relevantEdgeChanged(
            previous: first,
            next: second,
            direction: .contentMovesDown
        ))
    }

    private func makeInteriorAnimationImage(centerGray: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        context.setFillColor(CGColor(gray: centerGray, alpha: 1))
        context.fill(CGRect(x: 40, y: 80, width: 220, height: 240))
        return context.makeImage()
    }

    private func addFixedOverlay(to image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fill(CGRect(x: 50, y: 40, width: 60, height: 48))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fillEllipse(in: CGRect(x: 68, y: 52, width: 24, height: 24))
        return context.makeImage()
    }

    private func makeDirectionalDocument() -> CGImage? {
        guard let context = CGContext(data: nil, width: 160, height: 560, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 560))
        for y in stride(from: 0, to: 560, by: 7) {
            let value = CGFloat((y * 37 + y * y * 3) % 251) / 255
            context.setFillColor(CGColor(red: value, green: 1-value/2, blue: 0.2+value/3, alpha: 1))
            context.fill(CGRect(x: CGFloat((y * 13) % 45), y: CGFloat(y), width: CGFloat(80 + (y % 70)), height: CGFloat(2 + y % 5)))
        }
        return context.makeImage()
    }

    private func makeStripedImage(offset: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for y in stride(from: -20 + offset, to: 420, by: 34) {
            context.fill(CGRect(x: 20, y: y, width: 260, height: 3))
        }
        return context.makeImage()
    }
}

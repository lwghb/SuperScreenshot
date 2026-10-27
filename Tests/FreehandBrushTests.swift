import AppKit
import Testing
@testable import SuperScreenshot

@MainActor
struct FreehandBrushTests {
    private func canvas(scale: CGFloat = 1) -> ScreenshotEditorView {
        let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let view = ScreenshotEditorView(frame: CGRect(x: 0, y: 0, width: 200 * scale, height: 200 * scale),
                                        image: context.makeImage()!, imagePadding: 0)
        view.drawsBaseImage = false
        view.mode = .brush
        view.strokeColor = .red
        view.brushWidth = 4
        return view
    }

    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                          clickCount: 1, pressure: 1)!
    }

    private func alpha(_ view: ScreenshotEditorView, x: Int, y: Int) -> CGFloat {
        let bitmap = NSBitmapImageRep(cgImage: view.renderedImage()!)
        return bitmap.colorAt(x: x, y: 199 - y)!.alphaComponent
    }

    @Test func keepsBendsAndMouseUpEndpointAndUndoesWholeStroke() {
        let view = canvas()
        view.mouseDown(with: event(.leftMouseDown, 20, 20))
        view.mouseDragged(with: event(.leftMouseDragged, 100, 20))
        view.mouseUp(with: event(.leftMouseUp, 100, 100))
        #expect(alpha(view, x: 60, y: 20) > 0.9)
        #expect(alpha(view, x: 100, y: 80) > 0.9)
        #expect(alpha(view, x: 60, y: 60) == 0)
        view.undo()
        #expect(!view.hasAnnotations)
        #expect(alpha(view, x: 60, y: 20) == 0)
    }

    @Test func crossingStrokesCreateSeparateAnnotations() {
        let view = canvas()
        view.mouseDown(with: event(.leftMouseDown, 20, 100))
        view.mouseUp(with: event(.leftMouseUp, 180, 100))
        view.mouseDown(with: event(.leftMouseDown, 100, 100))
        view.mouseUp(with: event(.leftMouseUp, 100, 180))
        #expect(alpha(view, x: 100, y: 150) > 0.9)
        view.undo()
        #expect(alpha(view, x: 100, y: 150) == 0)
        #expect(alpha(view, x: 50, y: 100) > 0.9)
        view.mode = .arrow
        view.mouseDown(with: event(.leftMouseDown, 50, 100))
        view.mouseDragged(with: event(.leftMouseDragged, 50, 120))
        view.mouseUp(with: event(.leftMouseUp, 50, 120))
        #expect(alpha(view, x: 50, y: 100) == 0)
        #expect(alpha(view, x: 50, y: 120) > 0.9)
        view.deleteSelectedAnnotation()
        #expect(!view.hasAnnotations)
    }

    @Test func dotWidthScalesToOutputPixelsAndSurvivesImageOffset() {
        let view = canvas(scale: 0.5)
        view.mouseDown(with: event(.leftMouseDown, 50, 50))
        view.mouseUp(with: event(.leftMouseUp, 50, 50))
        #expect(alpha(view, x: 102, y: 100) > 0.9)
        #expect(alpha(view, x: 106, y: 100) == 0)
        view.brushWidth = 24
        #expect(alpha(view, x: 106, y: 100) == 0)
        let image = view.renderedImage()!
        view.replaceImage(image, annotationOffset: CGPoint(x: 20, y: 0))
        #expect(alpha(view, x: 100, y: 100) == 0)
        #expect(alpha(view, x: 120, y: 100) > 0.9)
    }
}

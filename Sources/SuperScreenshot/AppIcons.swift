import AppKit

func textAnnotationIcon() -> NSImage {
    let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
        let text = NSAttributedString(
            string: "T",
            attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
        )
        let size = text.size()
        text.draw(at: CGPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        ))
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = L("文字标注")
    return image
}

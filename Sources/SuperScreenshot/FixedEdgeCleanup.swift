import CoreGraphics

/// Finds stationary controls painted on a solid side margin. Replacing a
/// column is safe only while it still matches the verified viewport pattern.
struct FixedEdgeCleanup {
    struct Patch {
        let x: Int
        let image: CGImage
    }

    private struct Margin {
        let x: Int
        let width: Int
        let reference: [UInt32]
        let background: [UInt32?]

        init?(frames: [CGImage], offsets: [Int], x: Int, width: Int) {
            let height = frames[0].height
            let samples = frames.compactMap { FixedEdgeCleanup.pixels(in: $0, x: x, width: width) }
            guard samples.count == frames.count else { return nil }
            let reference = samples[0]
            let sampleStride = max(1, height / 64)
            var background = [UInt32?](repeating: nil, count: width)
            for column in 0..<width {
                var counts: [UInt32: Int] = [:]
                for row in stride(from: 0, to: height, by: sampleStride) {
                    counts[reference[row * width + column], default: 0] += 1
                }
                guard let color = counts.max(by: { $0.value < $1.value })?.key else { continue }
                var backgroundRows = 0
                var stationary = true
                var differsWhenAligned = false
                for row in 0..<height {
                    let index = row * width + column
                    let pixel = reference[index]
                    guard samples.dropFirst().allSatisfy({ $0[index] == pixel }) else {
                        stationary = false
                        break
                    }
                    if pixel == color {
                        backgroundRows += 1
                    } else if !differsWhenAligned {
                        for (sample, offset) in zip(samples.dropFirst(), offsets.dropFirst()) {
                            let alignedRow = row - offset
                            if (0..<height).contains(alignedRow),
                               sample[alignedRow * width + column] == color {
                                differsWhenAligned = true
                                break
                            }
                        }
                    }
                }
                if stationary, differsWhenAligned, backgroundRows * 5 >= height * 3 {
                    background[column] = color
                }
            }
            guard background.contains(where: { $0 != nil }) else { return nil }
            self.x = x
            self.width = width
            self.reference = reference
            self.background = background
        }

        func patches(for frame: CGImage) -> [Patch] {
            guard let pixels = FixedEdgeCleanup.pixels(in: frame, x: x, width: width),
                  pixels.count == reference.count else { return [] }
            var patches: [Patch] = []
            var colors: [UInt32] = []
            for column in 0...width {
                if column < width, let color = background[column],
                   stride(from: column, to: pixels.count, by: width).allSatisfy({ pixels[$0] == reference[$0] }) {
                    colors.append(color)
                    continue
                }
                if !colors.isEmpty,
                   let image = FixedEdgeCleanup.backgroundImage(colors: colors) {
                    patches.append(Patch(x: x + column - colors.count, image: image))
                }
                colors.removeAll(keepingCapacity: true)
            }
            return patches
        }
    }

    private let margins: [Margin]

    init?(frames: [CGImage], motions: [EdgeMotion]) {
        guard let first = frames.first, first.height >= 64 else { return nil }
        var samples = [first]
        var offsets = [0]
        var position = 0
        for (frame, motion) in zip(frames.dropFirst(), motions) {
            guard frame.width == first.width, frame.height == first.height else { return nil }
            let shift = min(first.height, max(0, motion.shift))
            position += motion.direction == .contentMovesUp ? shift : -shift
            guard offsets.allSatisfy({ abs($0 - position) >= 16 }) else { continue }
            samples.append(frame)
            offsets.append(position)
            if samples.count == 3 { break }
        }
        guard samples.count == 3 else { return nil }

        let width = min(128, first.width / 24)
        guard width > 0 else { return nil }
        margins = [0, first.width - width].compactMap {
            Margin(frames: samples, offsets: offsets, x: $0, width: width)
        }
        if margins.isEmpty { return nil }
    }

    func patches(for frame: CGImage) -> [Patch] {
        margins.flatMap { $0.patches(for: frame) }
    }

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    private static func pixels(in image: CGImage, x: Int, width: Int) -> [UInt32]? {
        guard let crop = image.cropping(to: CGRect(x: x, y: 0, width: width, height: image.height)) else { return nil }
        var pixels = [UInt32](repeating: 0, count: width * image.height)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: image.height))
            return true
        } ? pixels : nil
    }

    private static func backgroundImage(colors: [UInt32]) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: colors.count, height: 1,
            bitsPerComponent: 8, bytesPerRow: colors.count * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
        ), let destination = context.data else { return nil }
        colors.withUnsafeBytes { buffer in
            if let source = buffer.baseAddress {
                destination.copyMemory(from: source, byteCount: buffer.count)
            }
        }
        return context.makeImage()
    }
}

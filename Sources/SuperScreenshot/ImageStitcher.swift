import CoreGraphics

enum ScrollDirection: Equatable {
    case contentMovesUp
    case contentMovesDown
}

struct OverlapMatch {
    let direction: ScrollDirection
    let overlap: Int
    let score: Double
}

struct EdgeMotion: Equatable {
    let direction: ScrollDirection
    let shift: Int
    let score: Double
}

enum ImageStitcher {
    private static let edgeBandHeight = 10

    static func isNearlyIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let x = sample(a), let y = sample(b), x.count == y.count else { return false }
        var totalDifference = 0
        var changedPixels = 0
        var sampledPixels = 0
        for i in stride(from: 0, to: x.count, by: 3) {
            let difference = abs(Int(x[i]) - Int(y[i]))
            totalDifference += difference
            if difference > 5 { changedPixels += 1 }
            sampledPixels += 1
        }
        let meanDifference = Double(totalDifference) / Double(max(1, sampledPixels))
        let changedRatio = Double(changedPixels) / Double(max(1, sampledPixels))
        return meanDifference < 0.8 && changedRatio < 0.012
    }

    static func relevantEdgeChanged(
        previous: CGImage,
        next: CGImage,
        direction: ScrollDirection
    ) -> Bool {
        guard let a = edgeSample(previous, direction: direction),
              let b = edgeSample(next, direction: direction),
              a.count == b.count else { return false }
        var totalDifference = 0
        var changedPixels = 0
        for index in a.indices {
            let difference = abs(Int(a[index]) - Int(b[index]))
            totalDifference += difference
            if difference > 5 { changedPixels += 1 }
        }
        let meanDifference = Double(totalDifference) / Double(max(1, a.count))
        let changedRatio = Double(changedPixels) / Double(max(1, a.count))
        return meanDifference >= 1.0 || changedRatio >= 0.02
    }

    static func relevantEdgeIsStable(
        _ a: CGImage,
        _ b: CGImage,
        direction: ScrollDirection
    ) -> Bool {
        guard let x = edgeSample(a, direction: direction),
              let y = edgeSample(b, direction: direction),
              x.count == y.count else { return false }
        var totalDifference = 0
        var changedPixels = 0
        for index in x.indices {
            let difference = abs(Int(x[index]) - Int(y[index]))
            totalDifference += difference
            if difference > 4 { changedPixels += 1 }
        }
        let meanDifference = Double(totalDifference) / Double(max(1, x.count))
        let changedRatio = Double(changedPixels) / Double(max(1, x.count))
        return meanDifference < 0.7 && changedRatio < 0.01
    }

    static func stitch(_ frames: [CGImage]) -> CGImage? {
        var motions: [EdgeMotion] = []
        for pair in zip(frames, frames.dropFirst()) {
            let match = bestMatch(previous: pair.0, next: pair.1)
            motions.append(EdgeMotion(
                direction: match.direction,
                shift: max(1, pair.1.height - match.overlap),
                score: match.score
            ))
        }
        return stitch(frames, motions: motions)
    }

    static func stitch(_ frames: [CGImage], motions: [EdgeMotion]) -> CGImage? {
        guard let first = frames.first else { return nil }
        let width = first.width
        let slices = slices(from: frames, motions: motions)
        let totalHeight = slices.reduce(0) { $0 + $1.height }
        guard totalHeight < 100_000,
              let ctx = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = totalHeight
        for slice in slices {
            y -= slice.height
            ctx.draw(slice, in: CGRect(x: 0, y: y, width: width, height: slice.height))
        }
        return ctx.makeImage()
    }

    static func preview(
        _ frames: [CGImage],
        motions: [EdgeMotion],
        maximumWidth: Int = 280
    ) -> CGImage? {
        guard let first = frames.first else { return nil }
        let slices = slices(from: frames, motions: motions)
        let width = min(maximumWidth, first.width)
        let scale = CGFloat(width) / CGFloat(first.width)
        let heights = slices.map { max(1, Int((CGFloat($0.height) * scale).rounded())) }
        let totalHeight = heights.reduce(0, +)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        var y = totalHeight
        for (slice, height) in zip(slices, heights) {
            y -= height
            context.draw(slice, in: CGRect(x: 0, y: y, width: width, height: height))
        }
        return context.makeImage()
    }

    private static func slices(from frames: [CGImage], motions: [EdgeMotion]) -> [CGImage] {
        guard let first = frames.first else { return [] }
        var slices: [CGImage] = [first]
        for (index, next) in frames.dropFirst().enumerated() {
            guard index < motions.count else { break }
            let motion = motions[index]
            let added = min(next.height, max(1, motion.shift))
            switch motion.direction {
            case .contentMovesUp:
                let bottomRect = CGRect(x: 0, y: next.height - added, width: next.width, height: added)
                if let bottomSlice = next.cropping(to: bottomRect) { slices.append(bottomSlice) }
            case .contentMovesDown:
                let topRect = CGRect(x: 0, y: 0, width: next.width, height: added)
                if let topSlice = next.cropping(to: topRect) { slices.insert(topSlice, at: 0) }
            }
        }
        return slices
    }

    static func detectEdgeMotion(previous: CGImage, next: CGImage) -> EdgeMotion? {
        let height = min(previous.height, next.height)
        let width = min(128, min(previous.width, next.width))
        let anchorHeight = min(50, height)
        guard anchorHeight >= 10,
              let previousPixels = verticalSample(previous, width: width, height: height),
              let nextPixels = verticalSample(next, width: width, height: height) else { return nil }

        let topChanged = relevantEdgeChanged(previous: previous, next: next, direction: .contentMovesDown)
        let bottomChanged = relevantEdgeChanged(previous: previous, next: next, direction: .contentMovesUp)
        var best: EdgeMotion?
        let maximumShift = min(500, height - anchorHeight)

        for shift in 1...maximumShift {
            if bottomChanged {
                let score = anchorScore(
                    anchorImage: previousPixels,
                    candidateImage: nextPixels,
                    width: width,
                    anchorStartRow: height - anchorHeight,
                    candidateStartRow: height - anchorHeight - shift,
                    anchorHeight: anchorHeight
                )
                if best == nil || score < best!.score {
                    best = EdgeMotion(direction: .contentMovesUp, shift: shift, score: score)
                }
            }
            if topChanged {
                let score = anchorScore(
                    anchorImage: previousPixels,
                    candidateImage: nextPixels,
                    width: width,
                    anchorStartRow: 0,
                    candidateStartRow: shift,
                    anchorHeight: anchorHeight
                )
                if best == nil || score < best!.score {
                    best = EdgeMotion(direction: .contentMovesDown, shift: shift, score: score)
                }
            }
        }
        guard let best, best.score < 10 else { return nil }
        return best
    }

    static func detectAutomaticMotion(previous: CGImage, next: CGImage) -> EdgeMotion? {
        let height = min(previous.height, next.height)
        let width = min(128, min(previous.width, next.width))
        let bandHeight = min(40, max(12, height / 12))
        let maximumShift = min(160, height - bandHeight - 1)
        guard maximumShift >= 8,
              let previousPixels = verticalSample(previous, width: width, height: height),
              let nextPixels = verticalSample(next, width: width, height: height) else { return nil }

        let anchors = [0.28, 0.46, 0.64, 0.82].map {
            min(height - bandHeight, Int(Double(height - bandHeight) * $0))
        }
        var bestShift = 0
        var bestScore = Double.greatestFiniteMagnitude
        for shift in 8...maximumShift {
            var scores: [Double] = []
            for anchor in anchors where anchor - shift >= 0 {
                scores.append(anchorScore(
                    anchorImage: previousPixels,
                    candidateImage: nextPixels,
                    width: width,
                    anchorStartRow: anchor,
                    candidateStartRow: anchor - shift,
                    anchorHeight: bandHeight
                ))
            }
            guard scores.count >= 3 else { continue }
            scores.sort()
            // Ignore the worst band so one fixed overlay or animation cannot
            // dictate the displacement for the whole frame.
            let consensus = scores.dropLast().reduce(0, +) / Double(scores.count - 1)
            if consensus < bestScore {
                bestScore = consensus
                bestShift = shift
            }
        }
        guard bestShift > 0, bestScore < 10 else { return nil }
        return EdgeMotion(direction: .contentMovesUp, shift: bestShift, score: bestScore)
    }

    static func bestMatch(previous: CGImage, next: CGImage) -> OverlapMatch {
        guard let a = sample(previous), let b = sample(next) else {
            return OverlapMatch(direction: .contentMovesUp, overlap: previous.height / 3, score: .greatestFiniteMagnitude)
        }
        let sw = 96, sh = 128
        var forwardBest = sh / 2
        var forwardScore = Double.greatestFiniteMagnitude
        var backwardBest = sh / 2
        var backwardScore = Double.greatestFiniteMagnitude
        for overlap in stride(from: sh / 5, through: sh - 2, by: 1) {
            var forwardTotal = 0
            var backwardTotal = 0
            var count = 0
            for row in stride(from: 0, to: overlap, by: 2) {
                let previousBottomRow = sh - overlap + row
                let nextTopRow = row
                let previousTopRow = row
                let nextBottomRow = sh - overlap + row
                for col in stride(from: 8, to: sw-8, by: 4) {
                    forwardTotal += abs(Int(a[previousBottomRow*sw+col]) - Int(b[nextTopRow*sw+col]))
                    backwardTotal += abs(Int(a[previousTopRow*sw+col]) - Int(b[nextBottomRow*sw+col]))
                    count += 1
                }
            }
            let forwardNormalized = Double(forwardTotal) / Double(max(1, count))
            let backwardNormalized = Double(backwardTotal) / Double(max(1, count))
            if forwardNormalized < forwardScore {
                forwardScore = forwardNormalized
                forwardBest = overlap
            }
            if backwardNormalized < backwardScore {
                backwardScore = backwardNormalized
                backwardBest = overlap
            }
        }
        if forwardScore <= backwardScore {
            return OverlapMatch(
                direction: .contentMovesUp,
                overlap: Int(Double(forwardBest) / Double(sh) * Double(previous.height)),
                score: forwardScore
            )
        } else {
            return OverlapMatch(
                direction: .contentMovesDown,
                overlap: Int(Double(backwardBest) / Double(sh) * Double(previous.height)),
                score: backwardScore
            )
        }
    }

    private static func sample(_ image: CGImage) -> [UInt8]? {
        let width = 96, height = 128
        var bytes = [UInt8](repeating: 0, count: width*height)
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func edgeSample(
        _ image: CGImage,
        direction: ScrollDirection
    ) -> [UInt8]? {
        let bandHeight = min(edgeBandHeight, image.height)
        let y: Int
        switch direction {
        case .contentMovesUp:
            y = image.height - bandHeight
        case .contentMovesDown:
            y = 0
        }
        guard let band = image.cropping(to: CGRect(
            x: 0,
            y: y,
            width: image.width,
            height: bandHeight
        )) else { return nil }
        let width = min(256, max(1, band.width))
        var bytes = [UInt8](repeating: 0, count: width * bandHeight)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: bandHeight,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(band, in: CGRect(x: 0, y: 0, width: width, height: bandHeight))
        return bytes
    }

    private static func verticalSample(
        _ image: CGImage,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func anchorScore(
        anchorImage: [UInt8],
        candidateImage: [UInt8],
        width: Int,
        anchorStartRow: Int,
        candidateStartRow: Int,
        anchorHeight: Int
    ) -> Double {
        var total = 0
        var count = 0
        for row in 0..<anchorHeight {
            let anchorOffset = (anchorStartRow + row) * width
            let candidateOffset = (candidateStartRow + row) * width
            for column in stride(from: 0, to: width, by: 2) {
                total += abs(Int(anchorImage[anchorOffset + column]) - Int(candidateImage[candidateOffset + column]))
                count += 1
            }
        }
        return Double(total) / Double(max(1, count))
    }
}

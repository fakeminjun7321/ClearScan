import CoreImage
import CoreGraphics

struct BookSplit {
    let left: CIImage
    let right: CIImage
    let gutterRatio: CGFloat
    let usedAutomaticGutter: Bool
}

struct BookGutterEstimate {
    let ratio: CGFloat
    let confidence: CGFloat
    let hasTwoPageEvidence: Bool
}

/// Estimates a book gutter from a low-resolution luminance projection.
/// It supports asymmetrically framed spreads whose gutter is not exactly in
/// the center, while requiring image structure on both sides before the
/// detector treats a border-filling image as a two-page book.
final class BookPageSplitter {
    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    func split(image: CIImage, manualRatio: CGFloat?) throws -> BookSplit {
        let normalized = image.translatedToOrigin()
        let ratio: CGFloat
        let usedAutomaticGutter: Bool

        if let manualRatio {
            ratio = Self.clampGutter(manualRatio)
            usedAutomaticGutter = false
        } else {
            ratio = estimateGutter(in: normalized).ratio
            usedAutomaticGutter = true
        }

        let extent = normalized.extent.integral
        let splitX = extent.minX + extent.width * ratio
        guard splitX > extent.minX + 1, splitX < extent.maxX - 1 else {
            throw ScannerCoreError.renderingFailed
        }

        let leftRect = CGRect(
            x: extent.minX,
            y: extent.minY,
            width: splitX - extent.minX,
            height: extent.height
        ).integral
        let rightRect = CGRect(
            x: splitX,
            y: extent.minY,
            width: extent.maxX - splitX,
            height: extent.height
        ).integral

        return BookSplit(
            left: normalized.cropped(to: leftRect).translatedToOrigin(),
            right: normalized.cropped(to: rightRect).translatedToOrigin(),
            gutterRatio: ratio,
            usedAutomaticGutter: usedAutomaticGutter
        )
    }

    static func clampGutter(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, 0.25), 0.75)
    }

    func estimateGutter(in image: CIImage) -> BookGutterEstimate {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1 else {
            return BookGutterEstimate(
                ratio: 0.5,
                confidence: 0,
                hasTwoPageEvidence: false
            )
        }

        let targetWidth = 256
        let scale = CGFloat(targetWidth) / extent.width
        let targetHeight = max(96, min(384, Int((extent.height * scale).rounded())))
        let xScale = CGFloat(targetWidth) / extent.width
        let yScale = CGFloat(targetHeight) / extent.height
        let sampled = image.transformed(
            by: CGAffineTransform(scaleX: xScale, y: yScale)
        ).translatedToOrigin()

        var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            context.render(
                sampled,
                toBitmap: baseAddress,
                rowBytes: targetWidth * 4,
                bounds: bounds,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        let yStart = Int(CGFloat(targetHeight) * 0.08)
        let yEnd = max(yStart + 1, Int(CGFloat(targetHeight) * 0.92))
        var columnMeans = [CGFloat](repeating: 0, count: targetWidth)
        var columnDeviation = [CGFloat](repeating: 0, count: targetWidth)

        for x in 0 ..< targetWidth {
            var sum: CGFloat = 0
            var sumSquared: CGFloat = 0
            var samples: CGFloat = 0
            for y in yStart ..< yEnd {
                let offset = (y * targetWidth + x) * 4
                let luminance = CGFloat(pixels[offset]) * 0.299
                    + CGFloat(pixels[offset + 1]) * 0.587
                    + CGFloat(pixels[offset + 2]) * 0.114
                sum += luminance
                sumSquared += luminance * luminance
                samples += 1
            }
            let mean = sum / max(samples, 1)
            let variance = max(0, sumSquared / max(samples, 1) - mean * mean)
            columnMeans[x] = mean
            columnDeviation[x] = sqrt(variance)
        }

        let searchStart = Int(CGFloat(targetWidth) * 0.25)
        let searchEnd = Int(CGFloat(targetWidth) * 0.75)
        var bestX = targetWidth / 2
        var bestScore = -CGFloat.greatestFiniteMagnitude
        var bestValley: CGFloat = 0
        var bestTransition: CGFloat = 0
        var bestSideTexture: CGFloat = 0

        func mean(_ values: ArraySlice<CGFloat>) -> CGFloat {
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / CGFloat(values.count)
        }

        for x in searchStart ... searchEnd {
            let leftBandStart = max(0, x - 10)
            let leftBandEnd = max(leftBandStart + 1, x - 4)
            let rightBandStart = min(targetWidth - 1, x + 4)
            let rightBandEnd = min(targetWidth, x + 11)
            let leftMean = mean(columnMeans[leftBandStart ..< leftBandEnd])
            let rightMean = mean(columnMeans[rightBandStart ..< rightBandEnd])
            let sideMean = (leftMean + rightMean) * 0.5
            let darkValley = max(0, sideMean - columnMeans[x]) / 255
            let transition = abs(
                columnMeans[min(targetWidth - 1, x + 8)]
                    - columnMeans[max(0, x - 8)]
            ) / 255
            let uniformity = 1 - min(columnDeviation[x] / 40, 1)
            let centerDistance = abs(
                CGFloat(x) / CGFloat(targetWidth - 1) - 0.5
            )
            let centerBias = 1 - min(centerDistance / 0.25, 1)

            let leftTextureStart = Int(CGFloat(targetWidth) * 0.06)
            let leftTextureEnd = max(leftTextureStart + 1, x - 12)
            let rightTextureStart = min(targetWidth - 1, x + 12)
            let rightTextureEnd = Int(CGFloat(targetWidth) * 0.94)
            let leftTexture = mean(
                columnDeviation[leftTextureStart ..< leftTextureEnd]
            )
            let rightTexture =
                rightTextureStart < rightTextureEnd
                ? mean(columnDeviation[rightTextureStart ..< rightTextureEnd])
                : 0
            let sideTexture = min(leftTexture, rightTexture)
            let normalizedTexture = min(sideTexture / 20, 1)

            let score = darkValley * 0.55
                + transition * 0.27
                + uniformity * 0.08
                + centerBias * 0.04
                + normalizedTexture * 0.06

            if score > bestScore {
                bestScore = score
                bestX = x
                bestValley = darkValley
                bestTransition = transition
                bestSideTexture = sideTexture
            }
        }

        let gutterSignal = max(
            min(bestValley / 0.07, 1),
            min(bestTransition / 0.10, 1)
        )
        let textureSignal = min(bestSideTexture / 6, 1)
        let scoreSignal = min(max((bestScore - 0.09) / 0.08, 0), 1)
        let confidence =
            gutterSignal * 0.45
            + textureSignal * 0.35
            + scoreSignal * 0.20
        let hasTwoPageEvidence =
            bestSideTexture >= 2.5
            && (bestValley >= 0.025 || bestTransition >= 0.070)
            && bestScore >= 0.105

        return BookGutterEstimate(
            ratio: Self.clampGutter(
                CGFloat(bestX) / CGFloat(targetWidth - 1)
            ),
            confidence: min(max(confidence, 0), 1),
            hasTwoPageEvidence: hasTwoPageEvidence
        )
    }
}

extension CIImage {
    func translatedToOrigin() -> CIImage {
        guard extent.minX != 0 || extent.minY != 0 else { return self }
        return transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
    }
}

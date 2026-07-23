import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

struct ProcessedScannerCapture {
    let result: ScannerCaptureResult
    let correctedBookSpread: CIImage?
}

/// Full-resolution still processing. Call only from the scanner's dedicated
/// image-processing queue because CIContext and the Vision request are reused.
final class DocumentImageProcessor {
    private let context: CIContext
    private let rectangleDetector: VisionRectangleDetector
    private let bookSplitter: BookPageSplitter

    init() {
        let context = CIContext(options: [.cacheIntermediates: true])
        self.context = context
        rectangleDetector = VisionRectangleDetector()
        bookSplitter = BookPageSplitter(context: context)
    }

    func process(
        photoData: Data,
        fallbackQuadrilateral: DocumentQuadrilateral?,
        mode: ScannerCaptureMode,
        manualGutterRatio: CGFloat?
    ) throws -> ProcessedScannerCapture {
        guard let decoded = CIImage(
            data: photoData,
            options: [.applyOrientationProperty: true]
        ) else {
            throw ScannerCoreError.imageDecodingFailed
        }
        let source = decoded.translatedToOrigin()

        // Re-run rectangle detection on the full-resolution, orientation-
        // corrected still. The live video and photo outputs can have different
        // aspect ratios, so the live quad is only a last-resort fallback.
        let stillCandidate = try rectangleDetector.detect(
            image: source,
            mode: mode
        )
        guard let quadrilateral = stillCandidate?.quadrilateral ?? fallbackQuadrilateral else {
            throw ScannerCoreError.documentNotFound
        }

        let corrected = try perspectiveCorrect(
            image: source,
            quadrilateral: quadrilateral
        ).translatedToOrigin()

        switch mode {
        case .singlePage:
            let image = try render(corrected)
            return ProcessedScannerCapture(
                result: ScannerCaptureResult(
                    mode: .singlePage,
                    pages: [CapturedPage(side: .single, image: image)],
                    documentQuadrilateral: quadrilateral
                ),
                correctedBookSpread: nil
            )

        case .bookTwoPage:
            let result = try renderBook(
                correctedSpread: corrected,
                documentQuadrilateral: quadrilateral,
                manualGutterRatio: manualGutterRatio
            )
            return ProcessedScannerCapture(
                result: result,
                correctedBookSpread: corrected
            )
        }
    }

    func resplitBook(
        correctedSpread: CIImage,
        documentQuadrilateral: DocumentQuadrilateral,
        manualGutterRatio: CGFloat,
        capturedAt: Date
    ) throws -> ScannerCaptureResult {
        try renderBook(
            correctedSpread: correctedSpread,
            documentQuadrilateral: documentQuadrilateral,
            manualGutterRatio: manualGutterRatio,
            capturedAt: capturedAt
        )
    }

    private func perspectiveCorrect(
        image: CIImage,
        quadrilateral: DocumentQuadrilateral
    ) throws -> CIImage {
        let extent = image.extent
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = pixelPoint(quadrilateral.topLeft, in: extent)
        filter.topRight = pixelPoint(quadrilateral.topRight, in: extent)
        filter.bottomRight = pixelPoint(quadrilateral.bottomRight, in: extent)
        filter.bottomLeft = pixelPoint(quadrilateral.bottomLeft, in: extent)
        filter.crop = true

        guard let output = filter.outputImage, !output.extent.isEmpty else {
            throw ScannerCoreError.perspectiveCorrectionFailed
        }
        return output
    }

    private func pixelPoint(_ point: NormalizedPoint, in extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.minX + extent.width * point.x,
            y: extent.minY + extent.height * point.y
        )
    }

    private func renderBook(
        correctedSpread: CIImage,
        documentQuadrilateral: DocumentQuadrilateral,
        manualGutterRatio: CGFloat?,
        capturedAt: Date = Date()
    ) throws -> ScannerCaptureResult {
        let split = try bookSplitter.split(
            image: correctedSpread,
            manualRatio: manualGutterRatio
        )
        let leftImage = try render(split.left)
        let rightImage = try render(split.right)
        return ScannerCaptureResult(
            capturedAt: capturedAt,
            mode: .bookTwoPage,
            pages: [
                CapturedPage(side: .left, image: leftImage),
                CapturedPage(side: .right, image: rightImage),
            ],
            documentQuadrilateral: documentQuadrilateral,
            gutterRatio: split.gutterRatio,
            usedAutomaticGutter: split.usedAutomaticGutter
        )
    }

    private func render(_ image: CIImage) throws -> CGImage {
        let extent = image.extent.integral
        guard !extent.isEmpty,
              let output = context.createCGImage(image, from: extent)
        else {
            throw ScannerCoreError.renderingFailed
        }
        return output
    }
}

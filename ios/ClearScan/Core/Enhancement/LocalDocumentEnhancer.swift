import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation
import ImageIO

public enum ScanCorrectionPreset: String, CaseIterable, Identifiable, Sendable {
    case original
    case document
    case blackAndWhite
    case smartAuto

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "원본"
        case .document: "문서"
        case .blackAndWhite: "흑백"
        case .smartAuto: "스마트 자동"
        }
    }
}

public enum DocumentBlurSeverity: String, CaseIterable, Sendable {
    case none
    case mild
    case moderate
    case severe
}

/// A bounded-resolution measurement of document edge quality. `edgeSharpness`
/// is the normalized RMS Laplacian response around detected edges; it is a
/// readability proxy rather than a promise that lost characters can be
/// reconstructed.
public struct DocumentImageQualityAssessment: Equatable, Sendable {
    public let blurSeverity: DocumentBlurSeverity
    public let edgeSharpness: Double
    public let edgeDensity: Double
    public let recommendedStrength: Double
    public let isReliable: Bool

    public init(
        blurSeverity: DocumentBlurSeverity,
        edgeSharpness: Double,
        edgeDensity: Double,
        recommendedStrength: Double,
        isReliable: Bool
    ) {
        self.blurSeverity = blurSeverity
        self.edgeSharpness = edgeSharpness
        self.edgeDensity = edgeDensity
        self.recommendedStrength = min(max(recommendedStrength, 0), 1)
        self.isReliable = isReliable
    }
}

public protocol DocumentEnhancing: Sendable {
    func jpegData(
        for image: CGImage,
        preset: ScanCorrectionPreset,
        compressionQuality: CGFloat
    ) throws -> Data
}

public protocol DocumentDeblurring: Sendable {
    func qualityAssessment(
        for image: CGImage
    ) throws -> DocumentImageQualityAssessment

    /// Produces a separate enhanced JPEG. The input `CGImage` is immutable and
    /// remains untouched, allowing persistence to keep the original page.
    func deblurredJPEGData(
        for image: CGImage,
        compressionQuality: CGFloat
    ) throws -> Data
}

public enum DocumentEnhancementError: Error {
    case analysisFailed
    case renderingFailed
    case encodingFailed
}

/// Deterministic on-device document enhancement. This is deliberately not
/// labelled as generative AI: it measures edge acuity on a bounded thumbnail,
/// then applies a capped denoise + multi-stage luminance restoration pipeline.
/// The caps favor character fidelity over aggressive texture synthesis.
public final class LocalDocumentEnhancer:
    DocumentEnhancing,
    DocumentDeblurring,
    @unchecked Sendable
{
    private let context: CIContext
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private let analysisColorSpace = CGColorSpaceCreateDeviceGray()
    private let maximumAnalysisDimension: CGFloat = 768

    public init() {
        context = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false,
        ])
    }

    public func jpegData(
        for image: CGImage,
        preset: ScanCorrectionPreset,
        compressionQuality: CGFloat = 0.94
    ) throws -> Data {
        try autoreleasepool {
            let source = CIImage(cgImage: image).translatedToOrigin()
            let output: CIImage

            switch preset {
            case .original:
                output = source

            case .document:
                output = documentTone(from: source)

            case .blackAndWhite:
                output = blackAndWhiteDocument(from: source)

            case .smartAuto:
                let assessment = try qualityAssessment(for: image)
                let toned = documentTone(from: source)
                output = adaptiveDetailRestoration(
                    from: toned,
                    assessment: assessment,
                    preservesColor: false
                )
            }

            return try encode(
                output.cropped(to: source.extent),
                compressionQuality: compressionQuality
            )
        }
    }

    public func qualityAssessment(
        for image: CGImage
    ) throws -> DocumentImageQualityAssessment {
        let source = CIImage(cgImage: image).translatedToOrigin()
        let extent = source.extent.integral
        guard extent.width >= 3, extent.height >= 3 else {
            throw DocumentEnhancementError.analysisFailed
        }

        let scale = min(
            1,
            maximumAnalysisDimension / max(extent.width, extent.height)
        )
        let analysisImage = source
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .translatedToOrigin()
        let analysisExtent = analysisImage.extent.integral
        let width = Int(analysisExtent.width)
        let height = Int(analysisExtent.height)
        guard width >= 3, height >= 3 else {
            throw DocumentEnhancementError.analysisFailed
        }

        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                analysisImage,
                toBitmap: baseAddress,
                rowBytes: width,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .L8,
                colorSpace: analysisColorSpace
            )
        }

        var laplacianEnergy = 0.0
        var edgeCount = 0
        let gradientThreshold = 10
        for y in 1 ..< (height - 1) {
            let row = y * width
            for x in 1 ..< (width - 1) {
                let index = row + x
                let left = Int(pixels[index - 1])
                let right = Int(pixels[index + 1])
                let down = Int(pixels[index - width])
                let up = Int(pixels[index + width])
                let gradient = abs(right - left) + abs(up - down)
                guard gradient >= gradientThreshold else { continue }

                let center = Int(pixels[index])
                let laplacian = 4 * center - left - right - down - up
                laplacianEnergy += Double(laplacian * laplacian)
                edgeCount += 1
            }
        }

        let measuredPixelCount = max((width - 2) * (height - 2), 1)
        let edgeDensity = Double(edgeCount) / Double(measuredPixelCount)
        let isReliable = edgeCount >= 64 && edgeDensity >= 0.000_5
        let edgeSharpness: Double
        if edgeCount > 0 {
            edgeSharpness = sqrt(laplacianEnergy / Double(edgeCount)) / 255
        } else {
            edgeSharpness = 0
        }

        let severity: DocumentBlurSeverity
        let strength: Double
        if !isReliable {
            severity = .none
            strength = 0.12
        } else if edgeSharpness >= 0.32 {
            severity = .none
            strength = 0.14
        } else if edgeSharpness >= 0.20 {
            severity = .mild
            strength = 0.34
        } else if edgeSharpness >= 0.11 {
            severity = .moderate
            strength = 0.58
        } else {
            severity = .severe
            strength = 0.76
        }

        return DocumentImageQualityAssessment(
            blurSeverity: severity,
            edgeSharpness: edgeSharpness,
            edgeDensity: edgeDensity,
            recommendedStrength: strength,
            isReliable: isReliable
        )
    }

    public func deblurredJPEGData(
        for image: CGImage,
        compressionQuality: CGFloat = 0.94
    ) throws -> Data {
        try autoreleasepool {
            let source = CIImage(cgImage: image).translatedToOrigin()
            let assessment = try qualityAssessment(for: image)
            let restored = adaptiveDetailRestoration(
                from: source,
                assessment: assessment,
                preservesColor: true
            )
            return try encode(
                restored.cropped(to: source.extent),
                compressionQuality: compressionQuality
            )
        }
    }

    private func documentTone(from source: CIImage) -> CIImage {
        let highlights = CIFilter.highlightShadowAdjust()
        highlights.inputImage = source
        highlights.shadowAmount = 0.72
        highlights.highlightAmount = 0.92

        let colors = CIFilter.colorControls()
        colors.inputImage = highlights.outputImage
        colors.brightness = 0.025
        colors.contrast = 1.12
        colors.saturation = 0.82
        return (colors.outputImage ?? source).cropped(to: source.extent)
    }

    private func blackAndWhiteDocument(from source: CIImage) -> CIImage {
        let controls = CIFilter.colorControls()
        controls.inputImage = source
        controls.saturation = 0
        controls.contrast = 1.18
        controls.brightness = 0.02

        let monochrome = CIFilter.photoEffectNoir()
        monochrome.inputImage = controls.outputImage
        return (monochrome.outputImage ?? controls.outputImage ?? source)
            .cropped(to: source.extent)
    }

    private func adaptiveDetailRestoration(
        from source: CIImage,
        assessment: DocumentImageQualityAssessment,
        preservesColor: Bool
    ) -> CIImage {
        let strength = CGFloat(assessment.recommendedStrength)

        // Noise is reduced before edge restoration so sensor grain is not
        // mistaken for character detail. Values remain intentionally small.
        let denoise = CIFilter.noiseReduction()
        denoise.inputImage = source
        denoise.noiseLevel = Float(0.004 + strength * 0.010)
        denoise.sharpness = Float(0.18 + strength * 0.12)
        let denoised = (denoise.outputImage ?? source).cropped(to: source.extent)

        // Two restrained scales recover narrow and medium-width strokes. The
        // hard caps avoid the bright/dark ringing common with aggressive
        // deconvolution while still improving blurred text edge separation.
        let fine = CIFilter.unsharpMask()
        fine.inputImage = denoised
        fine.radius = Float(0.55 + strength * 0.60)
        fine.intensity = Float(0.16 + strength * 0.42)

        let luminance = CIFilter.sharpenLuminance()
        luminance.inputImage = fine.outputImage
        luminance.sharpness = Float(0.12 + strength * 0.28)

        let colors = CIFilter.colorControls()
        colors.inputImage = luminance.outputImage
        colors.brightness = 0
        colors.contrast = Float(1.0 + strength * 0.045)
        colors.saturation = preservesColor ? 1 : 0.96

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = colors.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return (clamp.outputImage ?? colors.outputImage ?? denoised)
            .cropped(to: source.extent)
    }

    private func encode(
        _ image: CIImage,
        compressionQuality: CGFloat
    ) throws -> Data {
        let extent = image.extent.integral
        guard !extent.isEmpty else {
            throw DocumentEnhancementError.renderingFailed
        }
        let quality = min(max(compressionQuality, 0), 1)
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String
        )
        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: outputColorSpace,
            options: [qualityKey: quality]
        ) else {
            throw DocumentEnhancementError.encodingFailed
        }
        return data
    }
}

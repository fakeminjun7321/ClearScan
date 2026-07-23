import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum DocumentIlluminationNormalizationError: Error {
  case kernelUnavailable
  case renderingFailed
}

/// Estimates the paper illumination with morphology + blur, then applies a
/// bounded Retinex-style gain map. Processing stays in Core Image so the app
/// does not allocate a second full-resolution CPU pixel buffer.
public final class DocumentIlluminationNormalizer: @unchecked Sendable {
  private let context: CIContext

  public init() {
    context = CIContext(options: [.cacheIntermediates: false])
  }

  public func normalizedImage(
    _ image: CGImage,
    strength: Double = 0.82
  ) throws -> CGImage {
    let source = CIImage(cgImage: image)
    let extent = source.extent.integral
    let minimumDimension = max(min(extent.width, extent.height), 1)

    let morphology = CIFilter.morphologyMaximum()
    morphology.inputImage = source
    morphology.radius = Float(min(max(minimumDimension * 0.035, 6), 48))

    let blur = CIFilter.gaussianBlur()
    blur.inputImage = morphology.outputImage ?? source
    blur.radius = Float(min(max(minimumDimension * 0.07, 12), 96))
    let background = (blur.outputImage ?? source).cropped(to: extent)

    // Divide blend computes the source paper color relative to its local
    // illumination map. Both inputs are Core Image built-ins; no deprecated
    // runtime kernel compilation is used.
    let divide = CIFilter.divideBlendMode()
    divide.inputImage = background
    divide.backgroundImage = source
    let normalized = (divide.outputImage ?? source).cropped(to: extent)

    let opacity = CIFilter.colorMatrix()
    opacity.inputImage = normalized
    opacity.aVector = CIVector(x: 0, y: 0, z: 0, w: min(max(strength, 0), 1))

    let blend = CIFilter.sourceOverCompositing()
    blend.inputImage = opacity.outputImage ?? normalized
    blend.backgroundImage = source
    guard
      let output = blend.outputImage?.cropped(to: extent),
      let rendered = context.createCGImage(output, from: extent)
    else {
      throw DocumentIlluminationNormalizationError.renderingFailed
    }
    return rendered
  }
}

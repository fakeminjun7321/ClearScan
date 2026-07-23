import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum ChromaticInkRemovalError: Error, Equatable {
  case kernelUnavailable
  case noEligibleRedOrBlueInk
  case tooMuchColoredContent
  case renderingFailed
}

/// Removes only strongly chromatic red/blue marks and reconstructs them from
/// nearby paper color. This is deliberately not described as semantic
/// handwriting removal: black handwriting and printed color graphics cannot be
/// distinguished without a dedicated model.
public final class ChromaticInkRemover: @unchecked Sendable {
  private let context: CIContext
  private let colorCubeData: Data
  private let maximumRemovalRatio: Double
  private let cubeDimension = 32

  public init(maximumRemovalRatio: Double = 0.18) {
    context = CIContext(options: [.cacheIntermediates: false])
    self.maximumRemovalRatio = min(max(maximumRemovalRatio, 0.01), 0.25)
    colorCubeData = Self.makeMaskCube(dimension: cubeDimension)
  }

  public func removeRedAndBlueInk(from image: CGImage) throws -> CGImage {
    let source = CIImage(cgImage: image)
    let extent = source.extent.integral
    let colorCube = CIFilter.colorCube()
    colorCube.inputImage = source
    colorCube.cubeDimension = Float(cubeDimension)
    colorCube.cubeData = colorCubeData
    guard let mask = colorCube.outputImage?.cropped(to: extent) else {
      throw ChromaticInkRemovalError.renderingFailed
    }

    let removalRatio = maskCoverage(mask.cropped(to: extent), extent: extent)
    guard removalRatio >= 0.00005 else {
      throw ChromaticInkRemovalError.noEligibleRedOrBlueInk
    }
    guard removalRatio <= maximumRemovalRatio else {
      throw ChromaticInkRemovalError.tooMuchColoredContent
    }

    let minimumDimension = max(min(extent.width, extent.height), 1)
    let background = CIFilter.morphologyMaximum()
    background.inputImage = source
    background.radius = Float(min(max(minimumDimension * 0.018, 5), 30))

    let dilateMask = CIFilter.morphologyMaximum()
    dilateMask.inputImage = mask
    dilateMask.radius = 1.2

    let softenMask = CIFilter.gaussianBlur()
    softenMask.inputImage = dilateMask.outputImage ?? mask
    softenMask.radius = 0.75

    let blend = CIFilter.blendWithMask()
    blend.inputImage = (background.outputImage ?? source).cropped(to: extent)
    blend.backgroundImage = source
    blend.maskImage = (softenMask.outputImage ?? mask).cropped(to: extent)
    guard
      let output = blend.outputImage?.cropped(to: extent),
      let result = context.createCGImage(output, from: extent)
    else {
      throw ChromaticInkRemovalError.renderingFailed
    }
    return result
  }

  private static func makeMaskCube(dimension: Int) -> Data {
    var values = [Float]()
    values.reserveCapacity(dimension * dimension * dimension * 4)
    let denominator = Float(dimension - 1)
    for blueIndex in 0 ..< dimension {
      let blue = Float(blueIndex) / denominator
      for greenIndex in 0 ..< dimension {
        let green = Float(greenIndex) / denominator
        for redIndex in 0 ..< dimension {
          let red = Float(redIndex) / denominator
          let maximum = max(red, green, blue)
          let minimum = min(red, green, blue)
          let chroma = maximum - minimum
          let redInk =
            chroma >= 0.16
            && red >= green * 1.18
            && red >= blue * 1.12
          let blueInk =
            chroma >= 0.14
            && blue >= red * 1.12
            && blue >= green * 1.08
          let mask: Float = redInk || blueInk ? 1 : 0
          values.append(contentsOf: [mask, mask, mask, 1])
        }
      }
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private func maskCoverage(_ mask: CIImage, extent: CGRect) -> Double {
    let longestSide = max(extent.width, extent.height)
    let scale = min(1, 256 / max(longestSide, 1))
    let width = max(1, Int((extent.width * scale).rounded()))
    let height = max(1, Int((extent.height * scale).rounded()))
    let translated = mask.transformed(
      by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    )
    let sampled = translated.transformed(
      by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height)
    )
    var bytes = [UInt8](repeating: 0, count: width * height)
    context.render(
      sampled,
      toBitmap: &bytes,
      rowBytes: width,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      format: .L8,
      colorSpace: nil
    )
    let activeCount = bytes.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
    return Double(activeCount) / Double(max(bytes.count, 1))
  }
}

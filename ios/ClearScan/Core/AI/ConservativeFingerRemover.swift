import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO
import Vision

public enum ConservativeFingerRemovalError: Error, Equatable {
  case noForegroundInstances
  case noConservativeCandidate
  case combinedCandidateAreaTooLarge
  case renderingFailed
}

struct ForegroundInstanceCandidate: Equatable, Sendable {
  let instanceID: Int
  let areaRatio: Double
  let touchesImageEdge: Bool
}

struct ConservativeFingerCandidatePolicy: Equatable, Sendable {
  let minimumAreaRatio: Double
  let maximumAreaRatio: Double
  let maximumAreaWithoutHandEvidence: Double

  init(
    minimumAreaRatio: Double = 0.0005,
    maximumAreaRatio: Double = 0.18,
    maximumAreaWithoutHandEvidence: Double = 0.08
  ) {
    self.minimumAreaRatio = minimumAreaRatio
    self.maximumAreaRatio = maximumAreaRatio
    self.maximumAreaWithoutHandEvidence = maximumAreaWithoutHandEvidence
  }

  func selectedInstances(
    from candidates: [ForegroundInstanceCandidate],
    hasHandEvidence: Bool
  ) throws -> IndexSet {
    guard !candidates.isEmpty else {
      throw ConservativeFingerRemovalError.noForegroundInstances
    }

    let eligible = candidates.filter { candidate in
      guard
        candidate.touchesImageEdge,
        candidate.areaRatio >= minimumAreaRatio,
        candidate.areaRatio <= maximumAreaRatio
      else {
        return false
      }
      return candidate.areaRatio <= maximumAreaWithoutHandEvidence || hasHandEvidence
    }
    guard !eligible.isEmpty else {
      throw ConservativeFingerRemovalError.noConservativeCandidate
    }

    let combinedArea = eligible.reduce(0) { $0 + $1.areaRatio }
    guard combinedArea <= maximumAreaRatio else {
      throw ConservativeFingerRemovalError.combinedCandidateAreaTooLarge
    }
    return IndexSet(eligible.map(\.instanceID))
  }
}

/// Conservative, on-device finger candidate removal.
///
/// Vision foreground segmentation proposes instances. Only small instances
/// that touch the image edge are eligible; medium candidates additionally
/// require a detected hand pose. A page-sized or ambiguous foreground mask is
/// rejected instead of risking document-content destruction.
public final class ConservativeFingerRemover: @unchecked Sendable {
  private let context: CIContext
  private let policy: ConservativeFingerCandidatePolicy

  public init() {
    context = CIContext(options: [.cacheIntermediates: false])
    policy = ConservativeFingerCandidatePolicy()
  }

  public func removeEdgeFinger(
    from image: CGImage,
    orientation: CGImagePropertyOrientation = .up
  ) throws -> CGImage {
    let foregroundRequest = VNGenerateForegroundInstanceMaskRequest()
    let handRequest = VNDetectHumanHandPoseRequest()
    handRequest.maximumHandCount = 2
    let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
    try handler.perform([foregroundRequest, handRequest])

    guard let observation = foregroundRequest.results?.first else {
      throw ConservativeFingerRemovalError.noForegroundInstances
    }
    let candidates = try observation.allInstances.map { instanceID in
      let mask = try observation.generateMask(forInstances: IndexSet(integer: instanceID))
      let metrics = try maskMetrics(mask)
      return ForegroundInstanceCandidate(
        instanceID: instanceID,
        areaRatio: metrics.areaRatio,
        touchesImageEdge: metrics.touchesEdge
      )
    }
    let selectedInstances = try policy.selectedInstances(
      from: candidates,
      hasHandEvidence: !(handRequest.results ?? []).isEmpty
    )
    let combinedMask = try observation.generateScaledMaskForImage(
      forInstances: selectedInstances,
      from: handler
    )
    return try repairedImage(
      source: CIImage(cgImage: image),
      mask: CIImage(cvPixelBuffer: combinedMask)
    )
  }

  private func maskMetrics(
    _ pixelBuffer: CVPixelBuffer
  ) throws -> (areaRatio: Double, touchesEdge: Bool) {
    let source = CIImage(cvPixelBuffer: pixelBuffer)
    let longestSide = max(source.extent.width, source.extent.height)
    let scale = min(1, 256 / max(longestSide, 1))
    let width = max(1, Int((source.extent.width * scale).rounded()))
    let height = max(1, Int((source.extent.height * scale).rounded()))
    let sampled = source.transformed(
      by: CGAffineTransform(scaleX: CGFloat(width) / source.extent.width, y: CGFloat(height) / source.extent.height)
    )
    let rowBytes = (width + 3) & ~3
    var bytes = [UInt8](repeating: 0, count: rowBytes * height)
    context.render(
      sampled,
      toBitmap: &bytes,
      rowBytes: rowBytes,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      format: .L8,
      colorSpace: nil
    )

    var activeCount = 0
    for y in 0 ..< height {
      let rowStart = y * rowBytes
      for x in 0 ..< width where bytes[rowStart + x] >= 128 {
        activeCount += 1
      }
    }
    guard activeCount > 0 else { return (0, false) }
    let edgeWidth = max(1, min(width, height) / 25)
    var edgeCount = 0
    for y in 0 ..< height {
      let rowStart = y * rowBytes
      for x in 0 ..< width where bytes[rowStart + x] >= 128 {
        if x < edgeWidth || x >= width - edgeWidth || y < edgeWidth || y >= height - edgeWidth {
          edgeCount += 1
        }
      }
    }
    let meaningfulEdgeContact = edgeCount >= max(2, activeCount / 1_000)
    return (
      Double(activeCount) / Double(max(width * height, 1)),
      meaningfulEdgeContact
    )
  }

  private func repairedImage(source: CIImage, mask: CIImage) throws -> CGImage {
    let extent = source.extent.integral
    let minimumDimension = max(min(extent.width, extent.height), 1)

    let background = CIFilter.morphologyMaximum()
    background.inputImage = source
    background.radius = Float(min(max(minimumDimension * 0.025, 8), 42))

    let softenBackground = CIFilter.gaussianBlur()
    softenBackground.inputImage = background.outputImage ?? source
    softenBackground.radius = 1.2

    let dilateMask = CIFilter.morphologyMaximum()
    dilateMask.inputImage = mask.cropped(to: extent)
    dilateMask.radius = 2

    let softenMask = CIFilter.gaussianBlur()
    softenMask.inputImage = dilateMask.outputImage ?? mask
    softenMask.radius = 1.1

    let blend = CIFilter.blendWithMask()
    blend.inputImage = (softenBackground.outputImage ?? source).cropped(to: extent)
    blend.backgroundImage = source
    blend.maskImage = (softenMask.outputImage ?? mask).cropped(to: extent)
    guard
      let output = blend.outputImage?.cropped(to: extent),
      let image = context.createCGImage(output, from: extent)
    else {
      throw ConservativeFingerRemovalError.renderingFailed
    }
    return image
  }
}

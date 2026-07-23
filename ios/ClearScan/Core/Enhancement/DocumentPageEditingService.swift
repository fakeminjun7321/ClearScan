import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

public enum PageRotation: Sendable {
  case left
  case right
}

public enum DocumentPageEditError: LocalizedError {
  case imageDecodingFailed
  case documentBoundsNotFound
  case renderingFailed

  public var errorDescription: String? {
    switch self {
    case .imageDecodingFailed:
      return "페이지 이미지를 읽지 못했습니다."
    case .documentBoundsNotFound:
      return "자동으로 자를 문서 테두리를 찾지 못했습니다."
    case .renderingFailed:
      return "편집한 페이지를 이미지로 만들지 못했습니다."
    }
  }
}

/// Pixel editing for the UIKit editor. These operations are deterministic
/// Core Image/Vision edits; only OCR is labelled as on-device AI in the UI.
public final class DocumentPageEditingService: @unchecked Sendable {
  private let context = CIContext(options: [
    .cacheIntermediates: false,
    .useSoftwareRenderer: false,
  ])
  private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    ?? CGColorSpaceCreateDeviceRGB()
  private let enhancer: DocumentEnhancing
  private let deblurrer: DocumentDeblurring

  public init(
    enhancer: DocumentEnhancing = LocalDocumentEnhancer(),
    deblurrer: DocumentDeblurring? = nil
  ) {
    self.enhancer = enhancer
    self.deblurrer =
      deblurrer
      ?? (enhancer as? DocumentDeblurring)
      ?? LocalDocumentEnhancer()
  }

  public func correctionData(
    from sourceData: Data,
    preset: ScanCorrectionPreset
  ) throws -> Data {
    let image = try cgImage(from: sourceData)
    return try enhancer.jpegData(
      for: image,
      preset: preset,
      compressionQuality: 0.94
    )
  }

  /// Applies the conservative, deterministic blur-correction path and returns
  /// a separate JPEG. Callers should persist it as the enhanced variant while
  /// retaining `sourceData` as the original page.
  public func deblurredData(
    from sourceData: Data,
    compressionQuality: CGFloat = 0.94
  ) throws -> Data {
    let image = try cgImage(from: sourceData)
    return try deblurrer.deblurredJPEGData(
      for: image,
      compressionQuality: compressionQuality
    )
  }

  public func qualityAssessment(
    from sourceData: Data
  ) throws -> DocumentImageQualityAssessment {
    try deblurrer.qualityAssessment(for: cgImage(from: sourceData))
  }

  public func rotatedData(from sourceData: Data, rotation: PageRotation) throws -> Data {
    let image = try orientedImage(from: sourceData)
    let orientation: CGImagePropertyOrientation
    switch rotation {
    case .left:
      orientation = .left
    case .right:
      orientation = .right
    }
    return try jpegData(from: image.oriented(orientation))
  }

  public func automaticallyCroppedData(from sourceData: Data) throws -> Data {
    let source = try orientedImage(from: sourceData).translatedToOrigin()
    let detector = VisionRectangleDetector()
    guard let candidate = try detector.detect(image: source) else {
      throw DocumentPageEditError.documentBoundsNotFound
    }

    return try perspectiveCorrectedData(
      from: source,
      quadrilateral: candidate.quadrilateral
    )
  }

  /// Shared perspective-correction path kept internal so coordinate handling
  /// can be verified independently from Vision's rectangle detector.
  func perspectiveCorrectedData(
    from sourceData: Data,
    quadrilateral: DocumentQuadrilateral
  ) throws -> Data {
    let source = try orientedImage(from: sourceData).translatedToOrigin()
    return try perspectiveCorrectedData(from: source, quadrilateral: quadrilateral)
  }

  private func perspectiveCorrectedData(
    from source: CIImage,
    quadrilateral: DocumentQuadrilateral
  ) throws -> Data {
    let extent = source.extent
    let filter = CIFilter.perspectiveCorrection()
    filter.inputImage = source
    filter.topLeft = pixelPoint(quadrilateral.topLeft, in: extent)
    filter.topRight = pixelPoint(quadrilateral.topRight, in: extent)
    filter.bottomRight = pixelPoint(quadrilateral.bottomRight, in: extent)
    filter.bottomLeft = pixelPoint(quadrilateral.bottomLeft, in: extent)
    filter.crop = true
    guard let output = filter.outputImage, !output.extent.isEmpty else {
      throw DocumentPageEditError.renderingFailed
    }
    return try jpegData(from: output.translatedToOrigin())
  }

  public func cgImage(from sourceData: Data) throws -> CGImage {
    let image = try orientedImage(from: sourceData).translatedToOrigin()
    let extent = image.extent.integral
    guard !extent.isEmpty, let output = context.createCGImage(image, from: extent) else {
      throw DocumentPageEditError.imageDecodingFailed
    }
    return output
  }

  private func orientedImage(from sourceData: Data) throws -> CIImage {
    guard let image = CIImage(
      data: sourceData,
      options: [.applyOrientationProperty: true]
    ) else {
      throw DocumentPageEditError.imageDecodingFailed
    }
    return image
  }

  private func jpegData(from image: CIImage) throws -> Data {
    let translated = image.translatedToOrigin()
    let extent = translated.extent.integral
    guard !extent.isEmpty else {
      throw DocumentPageEditError.renderingFailed
    }
    let qualityKey = CIImageRepresentationOption(
      rawValue: kCGImageDestinationLossyCompressionQuality as String
    )
    guard let data = context.jpegRepresentation(
      of: translated,
      colorSpace: outputColorSpace,
      options: [qualityKey: 0.94]
    ) else {
      throw DocumentPageEditError.renderingFailed
    }
    return data
  }

  private func pixelPoint(_ point: NormalizedPoint, in extent: CGRect) -> CGPoint {
    CGPoint(
      x: extent.minX + extent.width * point.x,
      y: extent.minY + extent.height * point.y
    )
  }
}

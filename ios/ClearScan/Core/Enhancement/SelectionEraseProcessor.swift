import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UIKit

public enum SelectionEraseError: LocalizedError, Equatable {
  case imageDecodingFailed
  case emptySelection
  case invalidCanvasSize
  case selectionTooLarge(actualRatio: Double, maximumRatio: Double)
  case renderingFailed
  case encodingFailed

  public var errorDescription: String? {
    switch self {
    case .imageDecodingFailed:
      "페이지 이미지를 읽지 못했습니다."
    case .emptySelection:
      "지울 영역을 먼저 칠해 주세요."
    case .invalidCanvasSize:
      "선택 영역의 크기가 올바르지 않습니다."
    case .selectionTooLarge(let actualRatio, let maximumRatio):
      "선택 영역이 너무 큽니다(\(Int(actualRatio * 100))%). 문서 보호를 위해 한 번에 \(Int(maximumRatio * 100))% 이하만 지울 수 있습니다."
    case .renderingFailed:
      "선택 영역을 복원하지 못했습니다."
    case .encodingFailed:
      "복원 결과를 JPEG로 만들지 못했습니다."
    }
  }
}

public struct SelectionEraseResult: Equatable, Sendable {
  public let jpegData: Data
  public let selectedAreaRatio: Double

  public init(jpegData: Data, selectedAreaRatio: Double) {
    self.jpegData = jpegData
    self.selectedAreaRatio = selectedAreaRatio
  }
}

/// Deterministic selected-area restoration for paper documents.
///
/// This is not semantic or generative AI. The user supplies the mask and the
/// selected pixels are conservatively filled from nearby light paper color.
/// Processing is bounded to a 4096-pixel longest edge and mask coverage is
/// sampled in at most 256² bytes before any destructive operation.
public final class SelectionEraseProcessor: @unchecked Sendable {
  private let context: CIContext
  private let maximumSelectionRatio: Double
  private let maximumOutputDimension: Int

  public init(
    maximumSelectionRatio: Double = 0.15,
    maximumOutputDimension: Int = 3_072
  ) {
    context = CIContext(options: [.cacheIntermediates: false])
    self.maximumSelectionRatio = min(max(maximumSelectionRatio, 0.01), 0.25)
    self.maximumOutputDimension = min(max(maximumOutputDimension, 1_024), 4_096)
  }

  public func process(
    sourceImageData: Data,
    selectionMask: CGImage,
    compressionQuality: CGFloat = 0.94
  ) throws -> SelectionEraseResult {
    let sourceImage = try downsampledImage(from: sourceImageData)
    let source = CIImage(cgImage: sourceImage)
    let extent = source.extent.integral
    let mask = normalizedMask(selectionMask, targetExtent: extent)
    let selectedAreaRatio = maskCoverage(mask, extent: extent)

    guard selectedAreaRatio >= 0.00005 else {
      throw SelectionEraseError.emptySelection
    }
    guard selectedAreaRatio <= maximumSelectionRatio else {
      throw SelectionEraseError.selectionTooLarge(
        actualRatio: selectedAreaRatio,
        maximumRatio: maximumSelectionRatio
      )
    }

    let minimumDimension = max(min(extent.width, extent.height), 1)
    let paperFill = CIFilter.morphologyMaximum()
    paperFill.inputImage = source
    paperFill.radius = Float(min(max(minimumDimension * 0.025, 10), 52))

    let smoothFill = CIFilter.gaussianBlur()
    smoothFill.inputImage = paperFill.outputImage ?? source
    smoothFill.radius = 1.4

    let dilatedMask = CIFilter.morphologyMaximum()
    dilatedMask.inputImage = mask
    dilatedMask.radius = 1.5

    let featheredMask = CIFilter.gaussianBlur()
    featheredMask.inputImage = dilatedMask.outputImage ?? mask
    featheredMask.radius = 0.9

    let blend = CIFilter.blendWithMask()
    blend.inputImage = (smoothFill.outputImage ?? source).cropped(to: extent)
    blend.backgroundImage = source
    blend.maskImage = (featheredMask.outputImage ?? mask).cropped(to: extent)
    guard
      let output = blend.outputImage?.cropped(to: extent),
      let rendered = context.createCGImage(output, from: extent)
    else {
      throw SelectionEraseError.renderingFailed
    }
    guard
      let jpegData = UIImage(cgImage: rendered).jpegData(
        compressionQuality: min(max(compressionQuality, 0.65), 1)
      )
    else {
      throw SelectionEraseError.encodingFailed
    }
    return SelectionEraseResult(
      jpegData: jpegData,
      selectedAreaRatio: selectedAreaRatio
    )
  }

  private func downsampledImage(from imageData: Data) throws -> CGImage {
    guard
      let source = CGImageSourceCreateWithData(
        imageData as CFData,
        [
          kCGImageSourceShouldCache: false
        ] as CFDictionary)
    else {
      throw SelectionEraseError.imageDecodingFailed
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumOutputDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        options as CFDictionary
      )
    else {
      throw SelectionEraseError.imageDecodingFailed
    }
    return image
  }

  private func normalizedMask(_ image: CGImage, targetExtent: CGRect) -> CIImage {
    let source = CIImage(cgImage: image)
    let translated = source.transformed(
      by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)
    )
    let scaled = translated.transformed(
      by: CGAffineTransform(
        scaleX: targetExtent.width / source.extent.width,
        y: targetExtent.height / source.extent.height
      ))

    // PencilKit renders selection strokes over transparency. Convert alpha to
    // an opaque luminance mask so color choice cannot affect coverage.
    let alphaMask = CIFilter.colorMatrix()
    alphaMask.inputImage = scaled
    let alphaToColor = CIVector(x: 0, y: 0, z: 0, w: 1)
    alphaMask.rVector = alphaToColor
    alphaMask.gVector = alphaToColor
    alphaMask.bVector = alphaToColor
    alphaMask.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    alphaMask.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    return (alphaMask.outputImage ?? scaled).cropped(to: targetExtent)
  }

  private func maskCoverage(_ mask: CIImage, extent: CGRect) -> Double {
    let longestSide = max(extent.width, extent.height)
    let scale = min(1, 256 / max(longestSide, 1))
    let width = max(1, Int((extent.width * scale).rounded()))
    let height = max(1, Int((extent.height * scale).rounded()))
    let sampled = mask.transformed(
      by: CGAffineTransform(
        scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height)
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
      for x in 0 ..< width where bytes[rowStart + x] >= 32 {
        activeCount += 1
      }
    }
    return Double(activeCount) / Double(max(width * height, 1))
  }
}

import CoreGraphics
import Foundation

public enum DocumentQualityIssue: String, CaseIterable, Equatable, Sendable {
  case blur
  case contentNearEdge
  case glare
  case unevenLighting
  case underexposed
}

public struct DocumentQualityReport: Equatable, Sendable {
  public let qualityScore: Double
  public let sharpnessScore: Double
  public let edgeContentRatio: Double
  public let glareRatio: Double
  public let illuminationUniformity: Double
  public let meanLuminance: Double
  public let issues: [DocumentQualityIssue]

  public init(
    qualityScore: Double,
    sharpnessScore: Double,
    edgeContentRatio: Double,
    glareRatio: Double,
    illuminationUniformity: Double,
    meanLuminance: Double,
    issues: [DocumentQualityIssue]
  ) {
    self.qualityScore = qualityScore
    self.sharpnessScore = sharpnessScore
    self.edgeContentRatio = edgeContentRatio
    self.glareRatio = glareRatio
    self.illuminationUniformity = illuminationUniformity
    self.meanLuminance = meanLuminance
    self.issues = issues
  }
}

public struct DocumentQualityThresholds: Equatable, Sendable {
  public var minimumSharpness: Double
  public var maximumEdgeContentRatio: Double
  public var maximumGlareRatio: Double
  public var minimumIlluminationUniformity: Double
  public var minimumMeanLuminance: Double

  public init(
    minimumSharpness: Double = 0.055,
    maximumEdgeContentRatio: Double = 0.18,
    maximumGlareRatio: Double = 0.015,
    minimumIlluminationUniformity: Double = 0.72,
    minimumMeanLuminance: Double = 72
  ) {
    self.minimumSharpness = minimumSharpness
    self.maximumEdgeContentRatio = maximumEdgeContentRatio
    self.maximumGlareRatio = maximumGlareRatio
    self.minimumIlluminationUniformity = minimumIlluminationUniformity
    self.minimumMeanLuminance = minimumMeanLuminance
  }
}

public enum DocumentQualityAnalysisError: Error {
  case samplingFailed
}

/// Bounded, deterministic document-quality analysis. Images are sampled into
/// at most `maximumSampleDimension²` grayscale bytes before metrics are
/// calculated, so full-resolution camera images do not create large temporary
/// pixel buffers.
public final class DocumentQualityAnalyzer: Sendable {
  private let maximumSampleDimension: Int
  private let thresholds: DocumentQualityThresholds

  public init(
    maximumSampleDimension: Int = 512,
    thresholds: DocumentQualityThresholds = DocumentQualityThresholds()
  ) {
    self.maximumSampleDimension = min(max(maximumSampleDimension, 64), 1_024)
    self.thresholds = thresholds
  }

  public func analyze(_ image: CGImage) throws -> DocumentQualityReport {
    let sample = try GrayscaleSample(image: image, maximumDimension: maximumSampleDimension)
    let sharpness = sample.sharpnessScore
    let edgeContent = sample.edgeContentRatio
    let lighting = sample.lightingMetrics
    let meanLuminance = sample.meanLuminance

    var issues: [DocumentQualityIssue] = []
    if sharpness < thresholds.minimumSharpness {
      issues.append(.blur)
    }
    if edgeContent > thresholds.maximumEdgeContentRatio {
      issues.append(.contentNearEdge)
    }
    if lighting.glareRatio > thresholds.maximumGlareRatio {
      issues.append(.glare)
    }
    if lighting.uniformity < thresholds.minimumIlluminationUniformity {
      issues.append(.unevenLighting)
    }
    if meanLuminance < thresholds.minimumMeanLuminance {
      issues.append(.underexposed)
    }

    var quality = 1.0
    if issues.contains(.blur) { quality -= 0.32 }
    if issues.contains(.contentNearEdge) { quality -= 0.23 }
    if issues.contains(.glare) { quality -= 0.18 }
    if issues.contains(.unevenLighting) { quality -= 0.17 }
    if issues.contains(.underexposed) { quality -= 0.15 }

    return DocumentQualityReport(
      qualityScore: min(max(quality, 0), 1),
      sharpnessScore: sharpness,
      edgeContentRatio: edgeContent,
      glareRatio: lighting.glareRatio,
      illuminationUniformity: lighting.uniformity,
      meanLuminance: meanLuminance,
      issues: issues
    )
  }
}

private struct GrayscaleSample {
  let width: Int
  let height: Int
  let pixels: [UInt8]

  init(image: CGImage, maximumDimension: Int) throws {
    let longestSide = max(image.width, image.height)
    let scale = min(1, Double(maximumDimension) / Double(longestSide))
    let sampleWidth = max(1, Int((Double(image.width) * scale).rounded()))
    let sampleHeight = max(1, Int((Double(image.height) * scale).rounded()))

    var buffer = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
    let rendered = buffer.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let baseAddress = bytes.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: sampleWidth,
          height: sampleHeight,
          bitsPerComponent: 8,
          bytesPerRow: sampleWidth,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
      else {
        return false
      }
      context.interpolationQuality = .medium
      context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight)
      )
      return true
    }
    guard rendered else { throw DocumentQualityAnalysisError.samplingFailed }
    width = sampleWidth
    height = sampleHeight
    pixels = buffer
  }

  var meanLuminance: Double {
    guard !pixels.isEmpty else { return 0 }
    return Double(pixels.reduce(into: UInt64.zero) { $0 += UInt64($1) })
      / Double(pixels.count)
  }

  var sharpnessScore: Double {
    guard width > 2, height > 2 else { return 0 }
    var squaredLaplacian = 0.0
    var count = 0
    for y in 1 ..< height - 1 {
      for x in 1 ..< width - 1 {
        let center = Double(pixel(x: x, y: y))
        let laplacian =
          4 * center
          - Double(pixel(x: x - 1, y: y))
          - Double(pixel(x: x + 1, y: y))
          - Double(pixel(x: x, y: y - 1))
          - Double(pixel(x: x, y: y + 1))
        squaredLaplacian += laplacian * laplacian
        count += 1
      }
    }
    guard count > 0 else { return 0 }
    return min(sqrt(squaredLaplacian / Double(count)) / 255, 1)
  }

  var edgeContentRatio: Double {
    guard !pixels.isEmpty else { return 0 }
    let background = percentile(pixels, fraction: 0.85)
    let foregroundThreshold = max(Int(background) - 42, 20)
    let edgeWidth = max(2, min(width, height) / 30)
    var foregroundCount = 0
    var edgeForegroundCount = 0

    for y in 0 ..< height {
      for x in 0 ..< width where Int(pixel(x: x, y: y)) < foregroundThreshold {
        foregroundCount += 1
        if x < edgeWidth || x >= width - edgeWidth || y < edgeWidth || y >= height - edgeWidth {
          edgeForegroundCount += 1
        }
      }
    }

    guard foregroundCount >= max(12, pixels.count / 500) else { return 0 }
    return Double(edgeForegroundCount) / Double(foregroundCount)
  }

  var lightingMetrics: (uniformity: Double, glareRatio: Double) {
    let columnCount = min(8, width)
    let rowCount = min(8, height)
    var cellBackgrounds: [UInt8] = []
    var cellClippedFractions: [Double] = []
    var cellPixelCounts: [Int] = []

    for row in 0 ..< rowCount {
      let minY = row * height / rowCount
      let maxY = max(minY + 1, (row + 1) * height / rowCount)
      for column in 0 ..< columnCount {
        let minX = column * width / columnCount
        let maxX = max(minX + 1, (column + 1) * width / columnCount)
        var values: [UInt8] = []
        values.reserveCapacity((maxX - minX) * (maxY - minY))
        var clippedCount = 0

        for y in minY ..< maxY {
          for x in minX ..< maxX {
            let value = pixel(x: x, y: y)
            values.append(value)
            if value >= 250 { clippedCount += 1 }
          }
        }
        guard !values.isEmpty else { continue }
        cellBackgrounds.append(percentile(values, fraction: 0.90))
        cellClippedFractions.append(Double(clippedCount) / Double(values.count))
        cellPixelCounts.append(values.count)
      }
    }

    guard !cellBackgrounds.isEmpty else { return (0, 0) }
    let lowBackground = Double(percentile(cellBackgrounds, fraction: 0.10))
    let highBackground = Double(percentile(cellBackgrounds, fraction: 0.90))
    let uniformity = 1 - min(max((highBackground - lowBackground) / 255, 0), 1)
    let medianBackground = Double(percentile(cellBackgrounds, fraction: 0.50))

    var hotspotPixels = 0.0
    for index in cellBackgrounds.indices {
      let background = Double(cellBackgrounds[index])
      let clippedFraction = cellClippedFractions[index]
      if background >= 248,
         background - medianBackground >= 12,
         clippedFraction >= 0.20
      {
        hotspotPixels += clippedFraction * Double(cellPixelCounts[index])
      }
    }
    let glareRatio = hotspotPixels / Double(max(pixels.count, 1))
    return (uniformity, glareRatio)
  }

  private func pixel(x: Int, y: Int) -> UInt8 {
    pixels[y * width + x]
  }

  private func percentile(_ values: [UInt8], fraction: Double) -> UInt8 {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(
      max(Int((Double(sorted.count - 1) * fraction).rounded()), 0),
      sorted.count - 1
    )
    return sorted[index]
  }
}

import CoreGraphics
import CoreImage
import XCTest

@testable import ClearScan

final class DocumentQualityAnalyzerTests: XCTestCase {
  private let analyzer = DocumentQualityAnalyzer(maximumSampleDimension: 256)

  func testBlurMetricDropsAfterGaussianBlur() throws {
    let sharp = try documentLineImage(width: 240, height: 320)
    let blurred = try gaussianBlur(sharp, radius: 7)

    let sharpReport = try analyzer.analyze(sharp)
    let blurredReport = try analyzer.analyze(blurred)

    XCTAssertGreaterThan(sharpReport.sharpnessScore, blurredReport.sharpnessScore * 2)
    XCTAssertTrue(blurredReport.issues.contains(.blur))
  }

  func testWarnsWhenForegroundContentTouchesImageEdge() throws {
    let cropped = try grayscaleImage(width: 240, height: 320) { x, y in
      if x < 5, y > 30, y < 290 { return 10 }
      return 242
    }
    let safelyInset = try grayscaleImage(width: 240, height: 320) { x, y in
      if x > 50, x < 60, y > 30, y < 290 { return 10 }
      return 242
    }

    let croppedReport = try analyzer.analyze(cropped)
    let insetReport = try analyzer.analyze(safelyInset)

    XCTAssertTrue(croppedReport.issues.contains(.contentNearEdge))
    XCTAssertFalse(insetReport.issues.contains(.contentNearEdge))
  }

  func testDetectsLocalizedClippedHighlightAndUnevenLighting() throws {
    let glare = try grayscaleImage(width: 240, height: 320) { x, y in
      if x > 80, x < 160, y > 110, y < 210 { return 255 }
      if y.isMultiple(of: 28), x > 24, x < 216 { return 35 }
      return 165
    }
    let shadow = try grayscaleImage(width: 240, height: 320) { x, y in
      let background = x < 120 ? UInt8(105) : UInt8(230)
      if y.isMultiple(of: 30), x > 20, x < 220 { return 25 }
      return background
    }

    let glareReport = try analyzer.analyze(glare)
    let shadowReport = try analyzer.analyze(shadow)

    XCTAssertTrue(glareReport.issues.contains(.glare))
    XCTAssertTrue(shadowReport.issues.contains(.unevenLighting))
  }

  func testAnalysisBufferIsBoundedForLargeInput() throws {
    let image = try grayscaleImage(width: 2_000, height: 3_000) { x, y in
      (x + y).isMultiple(of: 19) ? 40 : 235
    }
    let report = try DocumentQualityAnalyzer(maximumSampleDimension: 128).analyze(image)
    XCTAssertTrue((0 ... 1).contains(report.qualityScore))
  }

  private func documentLineImage(width: Int, height: Int) throws -> CGImage {
    try grayscaleImage(width: width, height: height) { x, y in
      if y > 30, y < height - 30, y.isMultiple(of: 16), x > 24, x < width - 24 {
        return 12
      }
      return 242
    }
  }

  private func gaussianBlur(_ image: CGImage, radius: Double) throws -> CGImage {
    let source = CIImage(cgImage: image)
    let filter = CIFilter(name: "CIGaussianBlur")!
    filter.setValue(source, forKey: kCIInputImageKey)
    filter.setValue(radius, forKey: kCIInputRadiusKey)
    let output = try XCTUnwrap(filter.outputImage?.cropped(to: source.extent))
    return try XCTUnwrap(CIContext().createCGImage(output, from: source.extent))
  }
}

func grayscaleImage(
  width: Int,
  height: Int,
  value: (Int, Int) -> UInt8
) throws -> CGImage {
  var pixels = [UInt8](repeating: 0, count: width * height)
  for y in 0 ..< height {
    for x in 0 ..< width {
      pixels[y * width + x] = value(x, y)
    }
  }
  let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
  return try XCTUnwrap(
    CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  )
}

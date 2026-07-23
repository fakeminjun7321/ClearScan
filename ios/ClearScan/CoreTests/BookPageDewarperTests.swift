import CoreGraphics
import XCTest

@testable import ClearScan

final class BookPageDewarperTests: XCTestCase {
  private let width = 360
  private let height = 480
  private let lineRows = Array(stride(from: 48, through: 432, by: 32))

  func testSyntheticCurvedGridBecomesQuantifiablyStraighter() throws {
    let flat = try textGridImage(width: width, height: height)
    let curved = try cylindricallyWarped(
      flat,
      gutterSide: .left,
      scaleAmplitude: -0.075,
      normalizedOffsetAmplitude: 0.008
    )

    let before = straightnessError(curved, expectedRows: lineRows)
    let result = BookPageDewarper(
      maximumAnalysisDimension: 480,
      minimumConfidence: 0.48
    ).dewarp(curved, gutterSide: .left)
    let after = straightnessError(result.image, expectedRows: lineRows)

    XCTAssertTrue(result.wasApplied, "\(String(describing: result.rejectionReason))")
    XCTAssertGreaterThan(result.diagnostics.confidence, 0.48)
    XCTAssertGreaterThan(before, 4)
    XCTAssertLessThan(after, before * 0.65)
    XCTAssertLessThan(
      meanAbsoluteDifference(result.image, flat),
      meanAbsoluteDifference(curved, flat) * 0.62
    )
  }

  func testRightGutterUsesMirroredGeometry() throws {
    let flat = try textGridImage(width: width, height: height)
    let curved = try cylindricallyWarped(
      flat,
      gutterSide: .right,
      scaleAmplitude: -0.068,
      normalizedOffsetAmplitude: -0.006
    )

    let before = straightnessError(curved, expectedRows: lineRows)
    let result = BookPageDewarper(
      maximumAnalysisDimension: 480,
      minimumConfidence: 0.48
    ).dewarp(curved, gutterSide: .right)
    let after = straightnessError(result.image, expectedRows: lineRows)

    XCTAssertTrue(result.wasApplied, "\(String(describing: result.rejectionReason))")
    XCTAssertLessThan(after, before * 0.65)
  }

  func testBlankPageIsReturnedByIdentityWhenEvidenceIsMissing() throws {
    let blank = try grayscaleImage(width: width, height: height) { _, _ in 246 }

    let result = BookPageDewarper().dewarp(blank, gutterSide: .left)

    XCTAssertFalse(result.wasApplied)
    XCTAssertEqual(result.rejectionReason, .insufficientLineEvidence)
    XCTAssertTrue(result.image === blank)
  }

  func testFlatGridIsNotDestructivelyWarped() throws {
    let flat = try textGridImage(width: width, height: height)

    let result = BookPageDewarper(
      maximumAnalysisDimension: 480,
      minimumConfidence: 0.48
    ).dewarp(flat, gutterSide: .left)

    XCTAssertFalse(result.wasApplied)
    XCTAssertTrue(result.image === flat)
  }

  private func textGridImage(width: Int, height: Int) throws -> CGImage {
    try grayscaleImage(width: width, height: height) { x, y in
      let isHorizontalRule =
        lineRows.contains(where: { abs(y - $0) <= 1 })
        && x >= 18
        && x < width - 18
      let isTextStroke =
        lineRows.contains(where: { y >= $0 - 7 && y <= $0 - 4 })
        && x >= 28
        && x < width - 28
        && (x / 11).isMultiple(of: 2)
      let isVerticalGrid =
        x >= 28
        && x < width - 28
        && x.isMultiple(of: 52)
        && y >= 30
        && y < height - 30
      if isHorizontalRule || isTextStroke { return 18 }
      if isVerticalGrid { return 176 }
      return 246
    }
  }

  private func cylindricallyWarped(
    _ image: CGImage,
    gutterSide: BookPageGutterSide,
    scaleAmplitude: Double,
    normalizedOffsetAmplitude: Double
  ) throws -> CGImage {
    let source = grayscalePixels(image)
    let centerY = Double(image.height - 1) * 0.5
    return try grayscaleImage(width: image.width, height: image.height) { x, y in
      let normalizedX = Double(x) / Double(max(image.width - 1, 1))
      let distance = gutterSide == .left ? normalizedX : 1 - normalizedX
      let weight = curveWeight(distance)
      let scale = 1 + scaleAmplitude * weight
      let offset = normalizedOffsetAmplitude * weight * Double(image.height)
      let flatY = min(
        max(centerY + (Double(y) - centerY - offset) / scale, 0),
        Double(image.height - 1)
      )
      return source[Int(flatY.rounded()) * image.width + x]
    }
  }

  private func straightnessError(
    _ image: CGImage,
    expectedRows: [Int]
  ) -> Double {
    let pixels = grayscalePixels(image)
    var totalDeviation = 0.0
    var sampleCount = 0
    for expectedY in expectedRows {
      var detectedRows: [Double] = []
      for x in stride(from: 24, to: image.width - 24, by: 12) {
        let lowerY = max(expectedY - 22, 0)
        let upperY = min(expectedY + 22, image.height - 1)
        var darkestY = lowerY
        var darkestValue = UInt8.max
        for y in lowerY...upperY {
          let value = pixels[y * image.width + x]
          if value < darkestValue {
            darkestValue = value
            darkestY = y
          }
        }
        if darkestValue < 100 {
          detectedRows.append(Double(darkestY))
        }
      }
      guard detectedRows.count >= 10 else { continue }
      let outerReference =
        detectedRows.suffix(max(detectedRows.count / 4, 1))
        .reduce(0, +) / Double(max(detectedRows.count / 4, 1))
      totalDeviation +=
        detectedRows.reduce(0) {
          $0 + abs($1 - outerReference)
        } / Double(detectedRows.count)
      sampleCount += 1
    }
    return sampleCount > 0 ? totalDeviation / Double(sampleCount) : .infinity
  }

  private func meanAbsoluteDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
    let lhsPixels = grayscalePixels(lhs)
    let rhsPixels = grayscalePixels(rhs)
    guard lhsPixels.count == rhsPixels.count else { return .infinity }
    return zip(lhsPixels, rhsPixels).reduce(0.0) {
      $0 + abs(Double($1.0) - Double($1.1))
    } / Double(lhsPixels.count)
  }

  private func grayscalePixels(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: image.width * image.height)
    let context = CGContext(
      data: &pixels,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    context.interpolationQuality = .none
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return pixels
  }

  private func curveWeight(_ gutterDistance: Double) -> Double {
    guard gutterDistance < 0.78 else { return 0 }
    let t = min(max(gutterDistance / 0.78, 0), 1)
    return 1 - t * t * (3 - 2 * t)
  }
}

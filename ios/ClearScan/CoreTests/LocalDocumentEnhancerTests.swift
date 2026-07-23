import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import XCTest

@testable import ClearScan

final class LocalDocumentEnhancerTests: XCTestCase {
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let enhancer = LocalDocumentEnhancer()

  func testDeblurImprovesBlurMetricAndReadabilityProxy() throws {
    let fixture = try textFixture(width: 1_200, height: 1_600)
    let blurred = try blurredImage(fixture, radius: 2.6)
    let inputAssessment = try enhancer.qualityAssessment(for: blurred)
    let inputReadability = readabilityProxy(in: blurred)

    let outputData = try enhancer.deblurredJPEGData(
      for: blurred,
      compressionQuality: 0.98
    )
    let output = try decodedImage(outputData)
    let outputAssessment = try enhancer.qualityAssessment(for: output)
    let outputReadability = readabilityProxy(in: output)
    print(
      "Gaussian fixture edgeSharpness "
        + "\(inputAssessment.edgeSharpness) -> \(outputAssessment.edgeSharpness); "
        + "readability \(inputReadability) -> \(outputReadability)"
    )

    XCTAssertEqual(output.width, blurred.width)
    XCTAssertEqual(output.height, blurred.height)
    XCTAssertGreaterThan(
      outputAssessment.edgeSharpness,
      inputAssessment.edgeSharpness * 1.08,
      "edge sharpness \(inputAssessment.edgeSharpness) -> \(outputAssessment.edgeSharpness)"
    )
    XCTAssertGreaterThan(
      outputReadability,
      inputReadability * 1.02,
      "readability \(inputReadability) -> \(outputReadability)"
    )
  }

  func testMotionBlurMitigationRaisesEdgeSharpnessWithoutChangingDimensions() throws {
    let fixture = try textFixture(width: 1_000, height: 1_400)
    let shaken = try motionBlurredImage(fixture, radius: 3.2)
    let before = try enhancer.qualityAssessment(for: shaken)

    let data = try enhancer.deblurredJPEGData(
      for: shaken,
      compressionQuality: 0.98
    )
    let output = try decodedImage(data)
    let after = try enhancer.qualityAssessment(for: output)
    print(
      "Motion fixture edgeSharpness "
        + "\(before.edgeSharpness) -> \(after.edgeSharpness)"
    )

    XCTAssertEqual(output.width, shaken.width)
    XCTAssertEqual(output.height, shaken.height)
    XCTAssertGreaterThan(after.edgeSharpness, before.edgeSharpness * 1.05)
  }

  func testDeblurCapsHalosNearHighContrastTextEdge() throws {
    let fixture = try highContrastEdgeFixture(width: 900, height: 500)
    let blurred = try blurredImage(fixture, radius: 1.8)
    let data = try enhancer.deblurredJPEGData(
      for: blurred,
      compressionQuality: 1
    )
    let output = try decodedImage(data)
    let samples = grayscalePixels(in: output, maximumDimension: 900)
    let width = min(output.width, 900)

    // The fixture's center third is black. This band is well inside the white
    // area but close enough to catch dark ringing from excessive sharpening.
    let startX = Int(Double(width) * 0.69)
    let endX = Int(Double(width) * 0.73)
    var minimumWhite = UInt8.max
    for y in Int(Double(samples.height) * 0.25) ..< Int(Double(samples.height) * 0.75) {
      for x in startX ..< endX {
        minimumWhite = min(minimumWhite, samples.pixels[y * samples.width + x])
      }
    }
    XCTAssertGreaterThanOrEqual(minimumWhite, 238)
  }

  func testLargeDocumentUsesBoundedAnalysisAndDirectJPEGEncoding() throws {
    let fixture = try textFixture(width: 2_200, height: 3_200)
    let assessment = try enhancer.qualityAssessment(for: fixture)
    let data = try enhancer.jpegData(
      for: fixture,
      preset: .smartAuto,
      compressionQuality: 0.9
    )
    let output = try decodedImage(data)

    XCTAssertTrue(assessment.isReliable)
    XCTAssertEqual(output.width, fixture.width)
    XCTAssertEqual(output.height, fixture.height)
    XCTAssertFalse(data.isEmpty)
  }

  private func textFixture(width: Int, height: Int) throws -> CGImage {
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    var image = CIImage(color: .white).cropped(to: extent)
    let scale = CGFloat(width) / 1_200
    let lineHeight = max(5, 8 * scale)
    let rowStep = max(40, 70 * scale)
    var y = 90 * CGFloat(height) / 1_600
    var row = 0
    while y < CGFloat(height) - rowStep {
      let left = CGFloat(width) * (row.isMultiple(of: 4) ? 0.11 : 0.16)
      let length = CGFloat(width) * (row.isMultiple(of: 3) ? 0.68 : 0.58)
      let line = CIImage(color: .black).cropped(
        to: CGRect(x: left, y: y, width: length, height: lineHeight)
      )
      image = line.composited(over: image)

      for column in 0 ..< 8 {
        let stemX = left + CGFloat(column) * length / 8
        let stem = CIImage(color: .black).cropped(
          to: CGRect(
            x: stemX,
            y: y,
            width: max(3, 4 * scale),
            height: lineHeight * 2.4
          )
        )
        image = stem.composited(over: image)
      }
      y += rowStep
      row += 1
    }
    return try XCTUnwrap(context.createCGImage(image, from: extent))
  }

  private func highContrastEdgeFixture(width: Int, height: Int) throws -> CGImage {
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    let background = CIImage(color: .white).cropped(to: extent)
    let stripe = CIImage(color: .black).cropped(
      to: CGRect(
        x: CGFloat(width) / 3,
        y: 0,
        width: CGFloat(width) / 3,
        height: CGFloat(height)
      )
    )
    return try XCTUnwrap(
      context.createCGImage(stripe.composited(over: background), from: extent)
    )
  }

  private func blurredImage(_ image: CGImage, radius: Float) throws -> CGImage {
    let source = CIImage(cgImage: image)
    let filter = CIFilter.gaussianBlur()
    filter.inputImage = source
    filter.radius = radius
    return try XCTUnwrap(
      context.createCGImage(
        (filter.outputImage ?? source).cropped(to: source.extent),
        from: source.extent
      )
    )
  }

  private func motionBlurredImage(_ image: CGImage, radius: Float) throws -> CGImage {
    let source = CIImage(cgImage: image)
    let filter = CIFilter.motionBlur()
    filter.inputImage = source
    filter.radius = radius
    filter.angle = 0.12
    return try XCTUnwrap(
      context.createCGImage(
        (filter.outputImage ?? source).cropped(to: source.extent),
        from: source.extent
      )
    )
  }

  private func decodedImage(_ data: Data) throws -> CGImage {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  private func readabilityProxy(in image: CGImage) -> Double {
    let samples = grayscalePixels(in: image, maximumDimension: 768)
    let sorted = samples.pixels.sorted()
    guard sorted.count >= 20 else { return 0 }
    let darkCount = max(sorted.count / 20, 1)
    let lightStart = sorted.count * 3 / 4
    let darkMean = sorted.prefix(darkCount).reduce(0.0) {
      $0 + Double($1)
    } / Double(darkCount)
    let lightValues = sorted[lightStart...]
    let lightMean = lightValues.reduce(0.0) {
      $0 + Double($1)
    } / Double(lightValues.count)
    return (lightMean - darkMean) / 255
  }

  private func grayscalePixels(
    in image: CGImage,
    maximumDimension: Int
  ) -> (pixels: [UInt8], width: Int, height: Int) {
    let source = CIImage(cgImage: image)
    let scale = min(
      1,
      CGFloat(maximumDimension) / max(source.extent.width, source.extent.height)
    )
    let scaled = source
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .translatedToOrigin()
    let width = Int(scaled.extent.width.rounded(.down))
    let height = Int(scaled.extent.height.rounded(.down))
    var pixels = [UInt8](repeating: 0, count: width * height)
    pixels.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      context.render(
        scaled,
        toBitmap: base,
        rowBytes: width,
        bounds: CGRect(x: 0, y: 0, width: width, height: height),
        format: .L8,
        colorSpace: CGColorSpaceCreateDeviceGray()
      )
    }
    return (pixels, width, height)
  }
}

import CoreImage
import Foundation
import UIKit
import XCTest

@testable import ClearScan

final class DocumentPageEditingServiceTests: XCTestCase {
  private let service = DocumentPageEditingService()
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpaceCreateDeviceRGB()

  func testLeftAndRightRotationPreserveDirectionAndSwapDimensions() throws {
    let sourceData = try quadrantImageData(width: 320, height: 180)

    let left = try decodedImage(
      service.rotatedData(from: sourceData, rotation: .left)
    )
    XCTAssertEqual(left.width, 180)
    XCTAssertEqual(left.height, 320)
    assertColor(.blue, in: left, normalizedX: 0.25, normalizedY: 0.25)
    assertColor(.red, in: left, normalizedX: 0.75, normalizedY: 0.25)
    assertColor(.yellow, in: left, normalizedX: 0.25, normalizedY: 0.75)
    assertColor(.green, in: left, normalizedX: 0.75, normalizedY: 0.75)

    let right = try decodedImage(
      service.rotatedData(from: sourceData, rotation: .right)
    )
    XCTAssertEqual(right.width, 180)
    XCTAssertEqual(right.height, 320)
    assertColor(.green, in: right, normalizedX: 0.25, normalizedY: 0.25)
    assertColor(.yellow, in: right, normalizedX: 0.75, normalizedY: 0.25)
    assertColor(.red, in: right, normalizedX: 0.25, normalizedY: 0.75)
    assertColor(.blue, in: right, normalizedX: 0.75, normalizedY: 0.75)
  }

  func testPerspectiveCorrectionUsesVisionLowerLeftCoordinates() throws {
    let sourceData = try horizontalHalvesImageData(width: 300, height: 300)
    let bottomHalf = DocumentQuadrilateral(
      topLeft: NormalizedPoint(x: 0.05, y: 0.45),
      topRight: NormalizedPoint(x: 0.95, y: 0.45),
      bottomRight: NormalizedPoint(x: 0.95, y: 0.05),
      bottomLeft: NormalizedPoint(x: 0.05, y: 0.05)
    )

    let corrected = try decodedImage(
      service.perspectiveCorrectedData(
        from: sourceData,
        quadrilateral: bottomHalf
      )
    )

    assertColor(.red, in: corrected, normalizedX: 0.5, normalizedY: 0.5)
  }

  func testDedicatedDeblurAPIProducesSeparateReadableJPEG() throws {
    let sourceData = try horizontalHalvesImageData(width: 600, height: 800)
    let assessment = try service.qualityAssessment(from: sourceData)
    let outputData = try service.deblurredData(
      from: sourceData,
      compressionQuality: 0.96
    )
    let output = try decodedImage(outputData)

    XCTAssertGreaterThan(outputData.count, 100)
    XCTAssertEqual(output.width, 600)
    XCTAssertEqual(output.height, 800)
    XCTAssertGreaterThanOrEqual(assessment.recommendedStrength, 0)
    XCTAssertLessThanOrEqual(assessment.recommendedStrength, 1)
  }

  private func quadrantImageData(width: CGFloat, height: CGFloat) throws -> Data {
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    let quadrants = [
      CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(
        to: CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
      ),
      CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(
        to: CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2)
      ),
      CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(
        to: CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2)
      ),
      CIImage(color: CIColor(red: 1, green: 1, blue: 0)).cropped(
        to: CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2)
      )
    ]
    let image = quadrants.reduce(CIImage(color: .black).cropped(to: extent)) {
      $1.composited(over: $0)
    }
    return try pngData(from: image, extent: extent)
  }

  private func horizontalHalvesImageData(width: CGFloat, height: CGFloat) throws -> Data {
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    let bottom = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(
      to: CGRect(x: 0, y: 0, width: width, height: height / 2)
    )
    let top = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(
      to: CGRect(x: 0, y: height / 2, width: width, height: height / 2)
    )
    return try pngData(from: top.composited(over: bottom), extent: extent)
  }

  private func pngData(from image: CIImage, extent: CGRect) throws -> Data {
    let cgImage = try XCTUnwrap(context.createCGImage(image, from: extent))
    return try XCTUnwrap(UIImage(cgImage: cgImage).pngData())
  }

  private func decodedImage(_ data: Data) throws -> CGImage {
    try XCTUnwrap(UIImage(data: data)?.cgImage)
  }

  private func assertColor(
    _ expected: TestColor,
    in image: CGImage,
    normalizedX: CGFloat,
    normalizedY: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let source = CIImage(cgImage: image)
    let bounds = CGRect(
      x: floor(CGFloat(image.width) * normalizedX),
      y: floor(CGFloat(image.height) * normalizedY),
      width: 1,
      height: 1
    )
    context.render(
      source,
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: bounds,
      format: .RGBA8,
      colorSpace: colorSpace
    )

    XCTAssertEqual(
      TestColor(red: pixel[0], green: pixel[1], blue: pixel[2]),
      expected,
      "Unexpected RGB value: \(pixel[0]), \(pixel[1]), \(pixel[2])",
      file: file,
      line: line
    )
  }
}

private enum TestColor: Equatable {
  case red
  case green
  case blue
  case yellow

  init(red: UInt8, green: UInt8, blue: UInt8) {
    if red > 160, green > 160, blue < 100 {
      self = .yellow
    } else if red > green, red > blue {
      self = .red
    } else if green > red, green > blue {
      self = .green
    } else {
      self = .blue
    }
  }
}

import CoreGraphics
import CoreImage
import XCTest

@testable import ClearScan

final class ChromaticInkRemoverTests: XCTestCase {
  func testRemovesRedAndBlueMarksButPreservesBlackContent() throws {
    let source = try rgbaImage(width: 160, height: 180) { x, _ in
      if 25 ..< 32 ~= x { return (230, 25, 30, 255) }
      if 65 ..< 72 ~= x { return (25, 45, 230, 255) }
      if 105 ..< 112 ~= x { return (15, 15, 15, 255) }
      return (244, 244, 239, 255)
    }

    let result = try ChromaticInkRemover().removeRedAndBlueInk(from: source)

    let redResult = rgb(result, x: 28, y: 90)
    let blueResult = rgb(result, x: 68, y: 90)
    let blackResult = rgb(result, x: 108, y: 90)
    XCTAssertGreaterThan(min(redResult.0, redResult.1, redResult.2), 180)
    XCTAssertGreaterThan(min(blueResult.0, blueResult.1, blueResult.2), 180)
    XCTAssertLessThan(max(blackResult.0, blackResult.1, blackResult.2), 80)
  }

  func testRejectsLargeColoredGraphic() throws {
    let source = try rgbaImage(width: 100, height: 100) { x, _ in
      x < 50 ? (230, 20, 20, 255) : (245, 245, 245, 255)
    }

    XCTAssertThrowsError(
      try ChromaticInkRemover().removeRedAndBlueInk(from: source)
    ) { error in
      XCTAssertEqual(error as? ChromaticInkRemovalError, .tooMuchColoredContent)
    }
  }

  func testRejectsImageWithoutEligibleColorInk() throws {
    let source = try rgbaImage(width: 80, height: 80) { _, _ in
      (235, 235, 235, 255)
    }

    XCTAssertThrowsError(
      try ChromaticInkRemover().removeRedAndBlueInk(from: source)
    ) { error in
      XCTAssertEqual(error as? ChromaticInkRemovalError, .noEligibleRedOrBlueInk)
    }
  }

  private func rgbaImage(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
  ) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0 ..< height {
      for x in 0 ..< width {
        let color = pixel(x, y)
        let offset = (y * width + x) * 4
        bytes[offset] = color.0
        bytes[offset + 1] = color.1
        bytes[offset + 2] = color.2
        bytes[offset + 3] = color.3
      }
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    return try XCTUnwrap(CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ))
  }

  private func rgb(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    CIContext().render(
      CIImage(cgImage: image),
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: CGRect(x: x, y: y, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return (pixel[0], pixel[1], pixel[2])
  }
}

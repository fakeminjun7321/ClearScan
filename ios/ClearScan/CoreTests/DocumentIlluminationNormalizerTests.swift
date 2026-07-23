import CoreGraphics
import CoreImage
import XCTest

@testable import ClearScan

final class DocumentIlluminationNormalizerTests: XCTestCase {
  func testReducesBackgroundDifferenceAcrossShadow() throws {
    let source = try grayscaleImage(width: 240, height: 320) { x, y in
      if y.isMultiple(of: 34), x > 20, x < 220 { return 25 }
      return x < 120 ? 105 : 220
    }

    let normalized = try DocumentIlluminationNormalizer().normalizedImage(source)

    let sourceDifference = abs(
      meanLuminance(source, rect: CGRect(x: 30, y: 40, width: 60, height: 240))
        - meanLuminance(source, rect: CGRect(x: 150, y: 40, width: 60, height: 240))
    )
    let normalizedDifference = abs(
      meanLuminance(normalized, rect: CGRect(x: 30, y: 40, width: 60, height: 240))
        - meanLuminance(normalized, rect: CGRect(x: 150, y: 40, width: 60, height: 240))
    )

    XCTAssertLessThan(normalizedDifference, sourceDifference * 0.45)
  }

  private func meanLuminance(_ image: CGImage, rect: CGRect) -> Double {
    var pixel = [UInt8](repeating: 0, count: 4)
    let filter = CIFilter(name: "CIAreaAverage")!
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
    CIContext().render(
      filter.outputImage!,
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
  }
}

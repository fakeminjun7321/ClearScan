import UIKit
import XCTest

@testable import ClearScan

final class DocumentImageProcessorTests: XCTestCase {
  func testManualCaptureUsesInsetFrameWhenNoRectangleIsVisible() throws {
    let size = CGSize(width: 600, height: 800)
    let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.9) {
      context in
      UIColor(white: 0.45, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }

    let fallback = DocumentQuadrilateral.insetFrame()
    let processed = try DocumentImageProcessor().process(
      photoData: data,
      fallbackQuadrilateral: fallback,
      mode: .singlePage,
      manualGutterRatio: nil
    )

    XCTAssertEqual(processed.result.pages.count, 1)
    XCTAssertEqual(processed.result.documentQuadrilateral, fallback)
    XCTAssertGreaterThan(processed.result.pages[0].image.width, 0)
    XCTAssertGreaterThan(processed.result.pages[0].image.height, 0)
  }

  func testInsetFrameClampsUnsafeInsets() {
    XCTAssertEqual(DocumentQuadrilateral.insetFrame(-1).area, 1, accuracy: 0.0001)
    XCTAssertEqual(DocumentQuadrilateral.insetFrame(1).area, 0.01, accuracy: 0.0001)
  }
}

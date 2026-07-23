import CoreImage
import PencilKit
import UIKit
import XCTest

@testable import ClearScan

final class SelectionEraseProcessorTests: XCTestCase {
  func testRestoresSelectedDarkMarkAndPreservesUnselectedContent() throws {
    let source = try sourceJPEG(width: 200, height: 260) { x, _ in
      if 36 ..< 43 ~= x || 132 ..< 139 ~= x { return .black }
      return UIColor(white: 0.95, alpha: 1)
    }
    let mask = try alphaMask(width: 200, height: 260) { x, _ in
      32 ..< 47 ~= x
    }

    let result = try SelectionEraseProcessor().process(
      sourceImageData: source,
      selectionMask: mask
    )
    let output = try XCTUnwrap(UIImage(data: result.jpegData)?.cgImage)
    let erased = rgb(output, x: 39, y: 130)
    let preserved = rgb(output, x: 135, y: 130)

    XCTAssertGreaterThan(min(erased.0, erased.1, erased.2), 180)
    XCTAssertLessThan(max(preserved.0, preserved.1, preserved.2), 80)
    XCTAssertGreaterThan(result.selectedAreaRatio, 0.01)
    XCTAssertLessThan(result.selectedAreaRatio, 0.15)
  }

  func testRejectsEmptySelection() throws {
    let source = try sourceJPEG(width: 100, height: 140) { _, _ in .white }
    let mask = try alphaMask(width: 100, height: 140) { _, _ in false }

    XCTAssertThrowsError(
      try SelectionEraseProcessor().process(
        sourceImageData: source,
        selectionMask: mask
      )
    ) { error in
      XCTAssertEqual(error as? SelectionEraseError, .emptySelection)
    }
  }

  func testRejectsSelectionAboveSafetyLimit() throws {
    let source = try sourceJPEG(width: 120, height: 160) { _, _ in .white }
    let mask = try alphaMask(width: 120, height: 160) { x, _ in x < 50 }

    XCTAssertThrowsError(
      try SelectionEraseProcessor(maximumSelectionRatio: 0.15).process(
        sourceImageData: source,
        selectionMask: mask
      )
    ) { error in
      guard case .selectionTooLarge(let actual, let maximum) = error as? SelectionEraseError else {
        return XCTFail("Expected selectionTooLarge, got \(error)")
      }
      XCTAssertGreaterThan(actual, 0.15)
      XCTAssertEqual(maximum, 0.15, accuracy: 0.0001)
    }
  }

  func testBoundsOutputResolution() throws {
    let source = try sourceJPEG(width: 1_600, height: 1_200) { x, y in
      x > 700 && x < 720 && y > 300 && y < 900 ? .black : .white
    }
    let mask = try alphaMask(width: 1_600, height: 1_200) { x, y in
      x > 690 && x < 730 && y > 290 && y < 910
    }

    let result = try SelectionEraseProcessor(maximumOutputDimension: 1_024).process(
      sourceImageData: source,
      selectionMask: mask
    )
    let output = try XCTUnwrap(UIImage(data: result.jpegData)?.cgImage)

    XCTAssertEqual(output.width, 1_024)
    XCTAssertEqual(output.height, 768)
  }

  func testPencilMaskRendererAndRotationScaling() throws {
    let drawing = selectionDrawing(
      from: CGPoint(x: 20, y: 30),
      to: CGPoint(x: 80, y: 110),
      width: 24
    )
    let mask = try SelectionEraserCanvasRenderer.maskImage(
      drawing: drawing,
      canvasSize: CGSize(width: 100, height: 140),
      sourcePixelSize: CGSize(width: 1_000, height: 1_400),
      maximumOutputDimension: 1_024
    )
    let rescaled = SelectionEraserCanvasRenderer.rescaledDrawing(
      drawing,
      from: CGSize(width: 100, height: 140),
      to: CGSize(width: 200, height: 280)
    )

    XCTAssertLessThanOrEqual(abs(mask.width - 731), 1)
    XCTAssertEqual(mask.height, 1_024)
    XCTAssertEqual(rescaled.bounds.midX, drawing.bounds.midX * 2, accuracy: 0.5)
    XCTAssertEqual(rescaled.bounds.midY, drawing.bounds.midY * 2, accuracy: 0.5)
    XCTAssertGreaterThan(rescaled.bounds.width, drawing.bounds.width * 1.7)
    XCTAssertGreaterThan(rescaled.bounds.height, drawing.bounds.height * 1.7)
  }

  func testPencilKitBrushMaskFeedsRealRestorationPipeline() throws {
    let source = try sourceJPEG(width: 200, height: 260) { x, _ in
      36 ..< 43 ~= x ? .black : UIColor(white: 0.95, alpha: 1)
    }
    let drawing = selectionDrawing(
      from: CGPoint(x: 39, y: 20),
      to: CGPoint(x: 39, y: 240),
      width: 18
    )
    let mask = try SelectionEraserCanvasRenderer.maskImage(
      drawing: drawing,
      canvasSize: CGSize(width: 200, height: 260),
      sourcePixelSize: CGSize(width: 200, height: 260),
      maximumOutputDimension: 3_072
    )

    let result = try SelectionEraseProcessor().process(
      sourceImageData: source,
      selectionMask: mask
    )
    let output = try XCTUnwrap(UIImage(data: result.jpegData)?.cgImage)
    let erased = rgb(output, x: 39, y: 130)

    XCTAssertGreaterThan(min(erased.0, erased.1, erased.2), 180)
    XCTAssertGreaterThan(result.selectedAreaRatio, 0)
    XCTAssertLessThan(result.selectedAreaRatio, 0.15)
  }

  @MainActor
  func testControllerHasAccessibleControlsAndCancelsOnce() throws {
    let source = try sourceJPEG(width: 240, height: 320) { _, _ in .white }
    var outcomes: [SelectionEraserOutcome] = []
    let controller = try SelectionEraserViewController(sourceImageData: source) {
      outcomes.append($0)
    }
    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.loadViewIfNeeded()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    controller.view.layoutIfNeeded()

    let identifiers = Set(allViews(in: controller.view).compactMap(\.accessibilityIdentifier))
    for identifier in [
      "selectionEraser.previewImage",
      "selectionEraser.canvas",
      "selectionEraser.undo",
      "selectionEraser.reset",
      "selectionEraser.preview",
      "selectionEraser.brushSize",
    ] {
      XCTAssertTrue(identifiers.contains(identifier), "Missing \(identifier)")
    }
    XCTAssertEqual(
      controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier,
      "selectionEraser.cancel"
    )
    XCTAssertEqual(
      controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier,
      "selectionEraser.save"
    )
    XCTAssertFalse(controller.navigationItem.rightBarButtonItem?.isEnabled ?? true)

    let cancel = try XCTUnwrap(controller.navigationItem.leftBarButtonItem)
    for _ in 0 ..< 2 {
      _ = UIApplication.shared.sendAction(
        try XCTUnwrap(cancel.action),
        to: cancel.target,
        from: cancel,
        for: nil
      )
    }
    XCTAssertEqual(outcomes, [.cancelled])
  }

  private func sourceJPEG(
    width: Int,
    height: Int,
    color: (Int, Int) -> UIColor
  ) throws -> Data {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).jpegData(
      withCompressionQuality: 0.96
    ) { context in
      for y in 0 ..< height {
        for x in 0 ..< width {
          color(x, y).setFill()
          context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
      }
    }
  }

  private func alphaMask(
    width: Int,
    height: Int,
    selected: (Int, Int) -> Bool
  ) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0 ..< height {
      for x in 0 ..< width where selected(x, y) {
        let offset = (y * width + x) * 4
        bytes[offset] = 255
        bytes[offset + 1] = 40
        bytes[offset + 2] = 40
        bytes[offset + 3] = 255
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
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ))
  }

  private func selectionDrawing(
    from start: CGPoint,
    to end: CGPoint,
    width: CGFloat
  ) -> PKDrawing {
    let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    let points = [start, midpoint, end].enumerated().map { index, location in
      PKStrokePoint(
        location: location,
        timeOffset: Double(index) * 0.05,
        size: CGSize(width: width, height: width),
        opacity: 0.8,
        force: 1,
        azimuth: 0,
        altitude: .pi / 2
      )
    }
    let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
    return PKDrawing(strokes: [
      PKStroke(
        ink: PKInk(.marker, color: UIColor.systemRed.withAlphaComponent(0.8)),
        path: path
      ),
    ])
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

  @MainActor
  private func allViews(in root: UIView) -> [UIView] {
    [root] + root.subviews.flatMap(allViews)
  }
}

import PencilKit
import UIKit
import XCTest

@testable import ClearScan

final class SignatureMarkupComposerTests: XCTestCase {
  func testCompositesNonEmptyDrawingWithoutMutatingSource() throws {
    let source = try sourceJPEG(size: CGSize(width: 240, height: 320))
    let originalCopy = source
    let drawing = signatureDrawing(
      from: CGPoint(x: 40, y: 150),
      to: CGPoint(x: 200, y: 150),
      color: .red
    )

    let output = try SignatureMarkupComposer.compositeJPEG(
      sourceImageData: source,
      drawing: drawing,
      canvasSize: CGSize(width: 240, height: 320)
    )

    XCTAssertEqual(source, originalCopy, "합성은 전달된 원본 데이터를 변경하면 안 됩니다.")
    let image = try XCTUnwrap(UIImage(data: output)?.cgImage)
    XCTAssertEqual(image.width, 240)
    XCTAssertEqual(image.height, 320)
    let center = rgba(image, x: 120, y: image.height - 150)
    XCTAssertGreaterThan(Int(center.0), Int(center.1) + 40)
    XCTAssertGreaterThan(Int(center.0), Int(center.2) + 40)
  }

  func testRejectsEmptyDrawing() throws {
    let source = try sourceJPEG(size: CGSize(width: 120, height: 180))

    XCTAssertThrowsError(
      try SignatureMarkupComposer.compositeJPEG(
        sourceImageData: source,
        drawing: PKDrawing(),
        canvasSize: CGSize(width: 120, height: 180)
      )
    ) { error in
      XCTAssertEqual(error as? SignatureMarkupError, .emptyDrawing)
    }
  }

  func testRescalesDrawingAcrossOrientationLayoutChange() {
    let drawing = signatureDrawing(
      from: CGPoint(x: 20, y: 30),
      to: CGPoint(x: 80, y: 100),
      color: .black
    )

    let rescaled = SignatureMarkupComposer.rescaledDrawing(
      drawing,
      from: CGSize(width: 100, height: 140),
      to: CGSize(width: 200, height: 280)
    )

    XCTAssertEqual(rescaled.bounds.midX, drawing.bounds.midX * 2, accuracy: 0.5)
    XCTAssertEqual(rescaled.bounds.midY, drawing.bounds.midY * 2, accuracy: 0.5)
    XCTAssertGreaterThan(rescaled.bounds.width, drawing.bounds.width * 1.9)
    XCTAssertGreaterThan(rescaled.bounds.height, drawing.bounds.height * 1.9)
  }

  func testBoundsOutputResolutionForLargePage() throws {
    let source = try sourceJPEG(size: CGSize(width: 1_600, height: 1_200))
    let drawing = signatureDrawing(
      from: CGPoint(x: 100, y: 100),
      to: CGPoint(x: 1_300, y: 900),
      color: .blue
    )

    let output = try SignatureMarkupComposer.compositeJPEG(
      sourceImageData: source,
      drawing: drawing,
      canvasSize: CGSize(width: 1_600, height: 1_200),
      maximumOutputDimension: 1_024
    )
    let image = try XCTUnwrap(UIImage(data: output)?.cgImage)

    XCTAssertEqual(max(image.width, image.height), 1_024)
    XCTAssertEqual(image.width, 1_024)
    XCTAssertEqual(image.height, 768)
  }

  @MainActor
  func testControllerExposesAccessibleControlsAndCancelsExactlyOnce() throws {
    let source = try sourceJPEG(size: CGSize(width: 240, height: 320))
    var outcomes: [SignatureMarkupOutcome] = []
    let controller = try SignatureMarkupViewController(sourceImageData: source) {
      outcomes.append($0)
    }
    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.loadViewIfNeeded()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    controller.view.layoutIfNeeded()

    let identifiers = Set(allViews(in: controller.view).compactMap(\.accessibilityIdentifier))
    XCTAssertTrue(identifiers.contains("signature.preview"))
    XCTAssertTrue(identifiers.contains("signature.canvas"))
    XCTAssertTrue(identifiers.contains("signature.undo"))
    XCTAssertTrue(identifiers.contains("signature.eraser"))
    XCTAssertEqual(
      controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier,
      "signature.cancel"
    )
    XCTAssertEqual(
      controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier,
      "signature.save"
    )
    XCTAssertFalse(controller.navigationItem.rightBarButtonItem?.isEnabled ?? true)

    let cancel = try XCTUnwrap(controller.navigationItem.leftBarButtonItem)
    _ = UIApplication.shared.sendAction(
      try XCTUnwrap(cancel.action),
      to: cancel.target,
      from: cancel,
      for: nil
    )
    _ = UIApplication.shared.sendAction(
      try XCTUnwrap(cancel.action),
      to: cancel.target,
      from: cancel,
      for: nil
    )
    XCTAssertEqual(outcomes, [.cancelled])
  }

  private func sourceJPEG(size: CGSize) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).jpegData(
      withCompressionQuality: 0.95
    ) { context in
      UIColor(white: 0.96, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
  }

  private func signatureDrawing(
    from start: CGPoint,
    to end: CGPoint,
    color: UIColor
  ) -> PKDrawing {
    let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    let points = [start, midpoint, end].enumerated().map { index, point in
      PKStrokePoint(
        location: point,
        timeOffset: TimeInterval(index) * 0.05,
        size: CGSize(width: 9, height: 9),
        opacity: 1,
        force: 1,
        azimuth: 0,
        altitude: .pi / 2
      )
    }
    let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
    return PKDrawing(strokes: [
      PKStroke(ink: PKInk(.pen, color: color), path: path),
    ])
  }

  private func rgba(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    CIContext().render(
      CIImage(cgImage: image),
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: CGRect(x: x, y: y, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return (pixel[0], pixel[1], pixel[2], pixel[3])
  }

  @MainActor
  private func allViews(in root: UIView) -> [UIView] {
    [root] + root.subviews.flatMap(allViews)
  }
}

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import XCTest

@testable import ClearScan

/// Deterministic synthetic fixtures covering common document-camera scenes.
/// Set `CLEARSCAN_TEST_ARTIFACTS` to save the rendered PNG inputs for review.
final class DetectionConditionMatrixTests: XCTestCase {
  private let frameExtent = CGRect(x: 0, y: 0, width: 900, height: 1_200)

  func testWhitePaperOnBrightDeskIsDetected() throws {
    let paperRect = normalizedRect(minX: 0.18, minY: 0.25, maxX: 0.82, maxY: 0.79)
    let desk = makeImage(color: CIColor(red: 0.87, green: 0.86, blue: 0.84))
    let paper = CIImage(color: CIColor(red: 0.99, green: 0.99, blue: 0.99))
      .cropped(to: paperRect)
    let image = textLines(on: paperRect, count: 8, luminance: 0.72, over: paper)
      .composited(over: desk)
      .cropped(to: frameExtent)
    try renderEvidence(image, name: "white-paper-bright-desk")

    let detected = try XCTUnwrap(VisionRectangleDetector().detect(image: image))

    assertCornersMatch(
      detected.quadrilateral,
      expected: corners(minX: 0.18, minY: 0.25, maxX: 0.82, maxY: 0.79),
      tolerance: 0.06
    )
    XCTAssertGreaterThanOrEqual(detected.quadrilateral.area, 0.25)
    XCTAssertLessThanOrEqual(detected.quadrilateral.area, 0.45)
  }

  func testOneSidedShadowDoesNotInflateQuad() throws {
    let paperRect = normalizedRect(minX: 0.2, minY: 0.28, maxX: 0.8, maxY: 0.78)
    let background = makeImage(color: CIColor(red: 0.32, green: 0.32, blue: 0.32))
    let paper = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.85))
      .cropped(to: paperRect)
    let lit = textLines(on: paperRect, count: 8, luminance: 0.4, over: paper)
      .composited(over: background)
    let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
      .cropped(to: normalizedRect(minX: 0, minY: 0, maxX: 0.45, maxY: 1))
    let image = shadow.composited(over: lit).cropped(to: frameExtent)
    try renderEvidence(image, name: "one-sided-shadow")

    let detected = try XCTUnwrap(VisionRectangleDetector().detect(image: image))

    assertCornersMatch(
      detected.quadrilateral,
      expected: corners(minX: 0.2, minY: 0.28, maxX: 0.8, maxY: 0.78),
      tolerance: 0.07
    )
  }

  func testRotatedPerspectivePaperCornersAccurate() throws {
    let targetTopLeft = CGPoint(x: 260, y: 780)
    let targetTopRight = CGPoint(x: 560, y: 830)
    let targetBottomRight = CGPoint(x: 640, y: 420)
    let targetBottomLeft = CGPoint(x: 350, y: 365)
    let baseRect = CGRect(x: 300, y: 390, width: 300, height: 420)
    let paper = CIImage(color: CIColor(red: 0.97, green: 0.97, blue: 0.97))
      .cropped(to: baseRect)
    let transform = CIFilter.perspectiveTransform()
    transform.inputImage = textLines(on: baseRect, count: 6, luminance: 0.3, over: paper)
    transform.topLeft = targetTopLeft
    transform.topRight = targetTopRight
    transform.bottomRight = targetBottomRight
    transform.bottomLeft = targetBottomLeft
    let warped = try XCTUnwrap(transform.outputImage)
    let background = makeImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25))
    let image = warped.composited(over: background).cropped(to: frameExtent)
    try renderEvidence(image, name: "rotated-perspective-paper")

    let detected = try XCTUnwrap(VisionRectangleDetector().detect(image: image))
    let expected = [
      targetTopLeft, targetTopRight, targetBottomRight, targetBottomLeft,
    ].map { point in
      NormalizedPoint(
        x: point.x / frameExtent.width,
        y: point.y / frameExtent.height
      )
    }
    assertCornersMatch(detected.quadrilateral, expected: expected, tolerance: 0.06)
  }

  func testBookSpreadDetectedAsSingleOuterRectangle() throws {
    let leftRect = normalizedRect(minX: 0.08, minY: 0.22, maxX: 0.485, maxY: 0.78)
    let rightRect = normalizedRect(minX: 0.515, minY: 0.22, maxX: 0.92, maxY: 0.78)
    let gutterRect = normalizedRect(minX: 0.485, minY: 0.22, maxX: 0.515, maxY: 0.78)
    let background = makeImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
    let leftPage = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9))
      .cropped(to: leftRect)
    let rightPage = CIImage(color: CIColor(red: 0.88, green: 0.88, blue: 0.88))
      .cropped(to: rightRect)
    let gutter = CIImage(color: CIColor(red: 0.38, green: 0.38, blue: 0.38))
      .cropped(to: gutterRect)
    let spread = gutter
      .composited(over: rightPage)
      .composited(over: leftPage)
      .composited(over: background)
    let image = textLines(
      on: rightRect,
      count: 7,
      luminance: 0.35,
      over: textLines(on: leftRect, count: 7, luminance: 0.35, over: spread)
    ).cropped(to: frameExtent)
    try renderEvidence(image, name: "book-spread")

    let detected = try XCTUnwrap(VisionRectangleDetector().detect(image: image))
    let (horizontalSpan, verticalSpan) = spans(of: detected.quadrilateral)
    XCTAssertGreaterThanOrEqual(horizontalSpan, 0.70)
    XCTAssertGreaterThanOrEqual(verticalSpan, 0.44)
    assertCornersMatch(
      detected.quadrilateral,
      expected: corners(minX: 0.08, minY: 0.22, maxX: 0.92, maxY: 0.78),
      tolerance: 0.07
    )
  }

  func testBottomClippedPaperOutlinesButSuppressesAutoCapture() throws {
    let paperRect = CGRect(
      x: 0.2 * frameExtent.width,
      y: -0.125 * frameExtent.height,
      width: 0.6 * frameExtent.width,
      height: 0.675 * frameExtent.height
    )
    let background = makeImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
    let paper = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95))
      .cropped(to: paperRect)
    let visibleTextRect = CGRect(x: 220, y: 60, width: 460, height: 540)
    let image = textured(
      textLines(on: visibleTextRect, count: 6, luminance: 0.4, over: paper)
        .composited(over: background)
        .cropped(to: frameExtent)
    )
    try renderEvidence(image, name: "bottom-clipped-paper")

    let detected = try XCTUnwrap(VisionRectangleDetector().detect(image: image))
    assertCornersMatch(
      detected.quadrilateral,
      expected: corners(minX: 0.2, minY: 0, maxX: 0.8, maxY: 0.55),
      tolerance: 0.06
    )
    XCTAssertTrue(detected.suppressesAutoCapture)
    XCTAssertGreaterThanOrEqual(maximumCornerMargin(of: detected.quadrilateral), 0.08)
  }

  func testThreeSideClippedPaperNeverYieldsUnsafeAutoCaptureCandidate() throws {
    let paperRect = CGRect(
      x: -0.08 * frameExtent.width,
      y: -0.1 * frameExtent.height,
      width: 0.58 * frameExtent.width,
      height: 0.65 * frameExtent.height
    )
    let background = makeImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
    let paper = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95))
      .cropped(to: paperRect)
    let image = textured(
      textLines(
        on: CGRect(x: 40, y: 60, width: 360, height: 540),
        count: 6,
        luminance: 0.4,
        over: paper
      )
      .composited(over: background)
      .cropped(to: frameExtent)
    )
    try renderEvidence(image, name: "three-side-clipped-paper")

    if let detected = try VisionRectangleDetector().detect(image: image) {
      XCTAssertGreaterThanOrEqual(
        maximumCornerMargin(of: detected.quadrilateral),
        0.08,
        "a border-hugging segmentation hallucination must not be surfaced"
      )
      XCTAssertTrue(detected.suppressesAutoCapture)
    }
  }

  func testTwoSeparateDocumentsAreNotMerged() throws {
    let leftRect = normalizedRect(minX: 0.06, minY: 0.3, maxX: 0.40, maxY: 0.7)
    let rightRect = normalizedRect(minX: 0.62, minY: 0.3, maxX: 0.94, maxY: 0.7)
    let background = makeImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25))
    let leftPage = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95))
      .cropped(to: leftRect)
    let rightPage = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95))
      .cropped(to: rightRect)
    let pages = rightPage.composited(over: leftPage).composited(over: background)
    let image = textLines(
      on: rightRect,
      count: 6,
      luminance: 0.4,
      over: textLines(on: leftRect, count: 6, luminance: 0.4, over: pages)
    ).cropped(to: frameExtent)
    try renderEvidence(image, name: "two-separate-documents")

    let detected = try XCTUnwrap(VisionRectangleDetector().detect(image: image))
    let (horizontalSpan, _) = spans(of: detected.quadrilateral)
    XCTAssertLessThanOrEqual(horizontalSpan, 0.55)
  }

  private func makeImage(color: CIColor) -> CIImage {
    CIImage(color: color).cropped(to: frameExtent)
  }

  private func normalizedRect(
    minX: CGFloat,
    minY: CGFloat,
    maxX: CGFloat,
    maxY: CGFloat
  ) -> CGRect {
    CGRect(
      x: minX * frameExtent.width,
      y: minY * frameExtent.height,
      width: (maxX - minX) * frameExtent.width,
      height: (maxY - minY) * frameExtent.height
    )
  }

  private func textLines(
    on rect: CGRect,
    count: Int,
    luminance: CGFloat,
    over image: CIImage
  ) -> CIImage {
    let horizontalInset = rect.width * 0.12
    let verticalInset = rect.height * 0.12
    let spacing = (rect.height - 2 * verticalInset) / CGFloat(max(count, 1))
    return (0..<count).reduce(image) { partial, index in
      let line = CGRect(
        x: rect.minX + horizontalInset,
        y: rect.maxY - verticalInset - CGFloat(index) * spacing,
        width: (rect.width - 2 * horizontalInset)
          * (index.isMultiple(of: 2) ? 0.94 : 0.74),
        height: 8
      )
      let ink = CIImage(color: CIColor(red: luminance, green: luminance, blue: luminance))
        .cropped(to: line)
      return ink.composited(over: partial)
    }
  }

  private func textured(_ image: CIImage) -> CIImage {
    let gradient = CIFilter(
      name: "CISmoothLinearGradient",
      parameters: [
        "inputPoint0": CIVector(x: 0, y: frameExtent.height),
        "inputPoint1": CIVector(x: frameExtent.width, y: 0),
        "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.10),
        "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.12),
      ]
    )!.outputImage!.cropped(to: frameExtent)
    let pattern = CIFilter(
      name: "CICheckerboardGenerator",
      parameters: [
        "inputCenter": CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.025),
        "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.025),
        "inputWidth": 6,
        "inputSharpness": 0.35,
      ]
    )!.outputImage!.cropped(to: frameExtent)
    return pattern.composited(over: gradient.composited(over: image))
  }

  private func corners(
    minX: CGFloat,
    minY: CGFloat,
    maxX: CGFloat,
    maxY: CGFloat
  ) -> [NormalizedPoint] {
    [
      NormalizedPoint(x: minX, y: maxY),
      NormalizedPoint(x: maxX, y: maxY),
      NormalizedPoint(x: maxX, y: minY),
      NormalizedPoint(x: minX, y: minY),
    ]
  }

  private func spans(
    of quadrilateral: DocumentQuadrilateral
  ) -> (horizontal: CGFloat, vertical: CGFloat) {
    let xs = quadrilateral.points.map(\.x)
    let ys = quadrilateral.points.map(\.y)
    return (
      horizontal: (xs.max() ?? 0) - (xs.min() ?? 0),
      vertical: (ys.max() ?? 0) - (ys.min() ?? 0)
    )
  }

  private func maximumCornerMargin(of quadrilateral: DocumentQuadrilateral) -> CGFloat {
    quadrilateral.points.map { point in
      min(point.x, 1 - point.x, point.y, 1 - point.y)
    }.max() ?? 0
  }

  private func assertCornersMatch(
    _ quadrilateral: DocumentQuadrilateral,
    expected: [NormalizedPoint],
    tolerance: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let detected = quadrilateral.points
    for corner in expected {
      let nearest = detected.map { point in
        hypot(point.x - corner.x, point.y - corner.y)
      }.min() ?? .greatestFiniteMagnitude
      XCTAssertLessThanOrEqual(nearest, tolerance, file: file, line: line)
    }
    for point in detected {
      let nearest = expected.map { corner in
        hypot(point.x - corner.x, point.y - corner.y)
      }.min() ?? .greatestFiniteMagnitude
      XCTAssertLessThanOrEqual(nearest, tolerance, file: file, line: line)
    }
  }

  @discardableResult
  private func renderEvidence(
    _ image: CIImage,
    name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> CGImage {
    let rendered = try XCTUnwrap(
      CIContext().createCGImage(image, from: image.extent),
      "failed to render synthetic image \(name)",
      file: file,
      line: line
    )
    guard
      let artifactsPath = ProcessInfo.processInfo.environment["CLEARSCAN_TEST_ARTIFACTS"],
      !artifactsPath.isEmpty
    else {
      return rendered
    }

    let directory = URL(fileURLWithPath: artifactsPath, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let url = directory.appendingPathComponent("\(name).png")
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil),
      "failed to create PNG destination at \(url.path)",
      file: file,
      line: line
    )
    CGImageDestinationAddImage(destination, rendered, nil)
    XCTAssertTrue(
      CGImageDestinationFinalize(destination),
      "failed to finalize PNG at \(url.path)",
      file: file,
      line: line
    )
    return rendered
  }
}

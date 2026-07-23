import CoreImage
import XCTest

@testable import ClearScan

final class VisionRectangleDetectorTests: XCTestCase {
  func testDetectsDocumentOccupyingLessThanTwelvePercentOfFrame() throws {
    let extent = CGRect(x: 0, y: 0, width: 1_000, height: 1_400)
    let page = CGRect(x: 330, y: 480, width: 340, height: 440)
    let background = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12))
      .cropped(to: extent)
    let border = CIImage(color: .black).cropped(to: page)
    let paper = CIImage(color: .white).cropped(to: page.insetBy(dx: 8, dy: 8))
    let image = paper.composited(over: border).composited(over: background)

    let candidate = try VisionRectangleDetector().detect(image: image)

    let detected = try XCTUnwrap(candidate)
    XCTAssertGreaterThan(detected.quadrilateral.area, 0.035)
    XCTAssertLessThan(detected.quadrilateral.area, 0.12)
  }

  func testStabilityTrackerToleratesHandheldJitter() throws {
    var tracker = RectangleStabilityTracker()
    let base = candidate(offsetX: 0, confidence: 0.8)

    XCTAssertFalse(try XCTUnwrap(tracker.update(candidate: base, timestamp: 0)).isStable)

    for index in 1 ... 9 {
      let jitter = index.isMultiple(of: 2) ? 0.008 : -0.006
      _ = tracker.update(
        candidate: candidate(offsetX: jitter, confidence: 0.8),
        timestamp: Double(index) * 0.1
      )
    }

    let detection = try XCTUnwrap(
      tracker.update(candidate: candidate(offsetX: 0.004, confidence: 0.8), timestamp: 1.0)
    )
    XCTAssertTrue(detection.isStable)
    XCTAssertEqual(detection.stabilityProgress, 1)
  }

  func testLowContrastDocumentUsesHybridDetection() throws {
    let extent = CGRect(x: 0, y: 0, width: 900, height: 1_200)
    let page = CGRect(x: 150, y: 170, width: 600, height: 850)
    let background = CIImage(color: CIColor(red: 0.45, green: 0.43, blue: 0.41))
      .cropped(to: extent)
    let paper = CIImage(color: CIColor(red: 0.72, green: 0.70, blue: 0.67))
      .cropped(to: page)
    let text = (0..<9).reduce(paper) { image, index in
      let line = CGRect(
        x: page.minX + 80,
        y: page.maxY - 150 - CGFloat(index * 65),
        width: 360 + CGFloat(index.isMultiple(of: 2) ? 50 : 0),
        height: 8
      )
      let ink = CIImage(color: CIColor(red: 0.34, green: 0.33, blue: 0.32))
        .cropped(to: line)
      return ink.composited(over: image)
    }
    let image = text.composited(over: background)

    let candidate = try VisionRectangleDetector().detect(image: image)

    let detected = try XCTUnwrap(candidate)
    XCTAssertGreaterThan(detected.quadrilateral.area, 0.40)
    XCTAssertLessThan(detected.quadrilateral.area, 0.60)
  }

  func testUniformFrameIsNotMistakenForBorderlessDocument() throws {
    let image = CIImage(color: CIColor(red: 0.78, green: 0.77, blue: 0.75))
      .cropped(to: CGRect(x: 0, y: 0, width: 900, height: 1_200))

    let candidate = try VisionRectangleDetector().detect(image: image)

    XCTAssertNil(candidate)
  }

  func testBookModeRecoversBorderFillingAsymmetricSpreadFromGutterEvidence() throws {
    let image = syntheticBorderFillingBookSpread()

    let analysis = try VisionRectangleDetector().analyze(
      image: image,
      mode: .bookTwoPage
    )

    let detected = try XCTUnwrap(analysis.candidate)
    XCTAssertEqual(detected.source, .bookSpreadInference)
    XCTAssertGreaterThan(detected.quadrilateral.area, 0.90)
    XCTAssertEqual(
      try XCTUnwrap(analysis.suggestedBookGutterRatio),
      0.66,
      accuracy: 0.07
    )

    let split = try BookPageSplitter(context: CIContext()).split(
      image: image,
      manualRatio: nil
    )
    XCTAssertTrue(split.usedAutomaticGutter)
    XCTAssertEqual(split.gutterRatio, 0.66, accuracy: 0.07)
    XCTAssertGreaterThan(split.left.extent.width, split.right.extent.width)
  }

  func testSinglePageModeDoesNotUseBookSpreadInference() throws {
    let analysis = try VisionRectangleDetector().analyze(
      image: syntheticBorderFillingBookSpread(),
      mode: .singlePage
    )

    XCTAssertNotEqual(analysis.candidate?.source, .bookSpreadInference)
  }

  func testUniformBookFrameDoesNotUseBookSpreadInference() throws {
    let image = CIImage(color: CIColor(red: 0.84, green: 0.83, blue: 0.80))
      .cropped(to: CGRect(x: 0, y: 0, width: 1_200, height: 900))

    let analysis = try VisionRectangleDetector().analyze(
      image: image,
      mode: .bookTwoPage
    )

    XCTAssertNotEqual(analysis.candidate?.source, .bookSpreadInference)
    XCTAssertNil(analysis.suggestedBookGutterRatio)
  }

  func testStabilityProgressSurvivesOneMissedFrameWithoutCapturing() throws {
    var tracker = RectangleStabilityTracker()
    let page = candidate(offsetX: 0, confidence: 0.8)
    for index in 0 ... 4 {
      _ = tracker.update(candidate: page, timestamp: Double(index) * 0.1)
    }

    let missed = try XCTUnwrap(tracker.update(candidate: nil, timestamp: 0.5))
    XCTAssertGreaterThan(missed.stabilityProgress, 0.3)
    XCTAssertFalse(missed.isStable)

    let recovered = try XCTUnwrap(tracker.update(candidate: page, timestamp: 0.6))
    XCTAssertGreaterThan(recovered.stabilityProgress, missed.stabilityProgress)
  }

  func testStabilityTrackerKeepsOverlayAcrossBriefVisionMisses() throws {
    var tracker = RectangleStabilityTracker()
    _ = tracker.update(candidate: candidate(offsetX: 0, confidence: 0.8), timestamp: 0)

    for index in 1 ... 5 {
      XCTAssertNotNil(tracker.update(candidate: nil, timestamp: Double(index) * 0.11))
    }
    XCTAssertNil(tracker.update(candidate: nil, timestamp: 0.66))
  }

  func testStabilityTrackerIgnoresAnOccasionalOutlier() throws {
    var tracker = RectangleStabilityTracker()
    let page = candidate(offsetX: 0, confidence: 0.8)

    for index in 0 ... 3 {
      _ = tracker.update(candidate: page, timestamp: Double(index) * 0.1)
    }
    let outlier = candidate(offsetX: 0.28, confidence: 0.95)
    let interrupted = try XCTUnwrap(
      tracker.update(candidate: outlier, timestamp: 0.4)
    )
    XCTAssertFalse(interrupted.isStable)
    XCTAssertEqual(interrupted.stabilityProgress, 0)

    for index in 5 ... 8 {
      _ = tracker.update(candidate: page, timestamp: Double(index) * 0.1)
    }
    let recovered = try XCTUnwrap(
      tracker.update(candidate: page, timestamp: 0.9)
    )
    XCTAssertTrue(recovered.isStable)
    XCTAssertEqual(recovered.stabilityProgress, 1)
    XCTAssertEqual(recovered.quadrilateral.topLeft.x, 0.18, accuracy: 0.001)
  }

  func testStabilityTrackerDoesNotCaptureStalePageAfterLargeMove() throws {
    var tracker = RectangleStabilityTracker()
    let firstPage = candidate(offsetX: 0, confidence: 0.8)
    for index in 0 ... 7 {
      _ = tracker.update(candidate: firstPage, timestamp: Double(index) * 0.1)
    }

    let movedPage = candidate(offsetX: 0.24, confidence: 0.8)
    let moved = try XCTUnwrap(
      tracker.update(candidate: movedPage, timestamp: 0.8)
    )
    XCTAssertFalse(moved.isStable)
    XCTAssertEqual(moved.stabilityProgress, 0)
  }

  func testStabilityTrackerAcceptsAlternatingVisionSourcesForSamePage() throws {
    var tracker = RectangleStabilityTracker()

    var finalDetection: LiveRectangleDetection?
    for index in 0 ... 7 {
      let source: RectangleDetectionSource =
        index.isMultiple(of: 2) ? .documentSegmentation : .rectangle
      finalDetection = tracker.update(
        candidate: RectangleCandidate(
          quadrilateral: candidate(offsetX: 0, confidence: 0.8).quadrilateral,
          confidence: 0.8,
          source: source
        ),
        timestamp: Double(index) * 0.1
      )
    }

    XCTAssertTrue(try XCTUnwrap(finalDetection).isStable)
  }

  func testVideoRotationAnglesMapToExplicitVisionOrientations() {
    XCTAssertEqual(ScannerFrameOrientation(videoRotationAngle: 0), .up)
    XCTAssertEqual(ScannerFrameOrientation(videoRotationAngle: 90), .right)
    XCTAssertEqual(ScannerFrameOrientation(videoRotationAngle: 180), .down)
    XCTAssertEqual(ScannerFrameOrientation(videoRotationAngle: 270), .left)
    XCTAssertEqual(ScannerFrameOrientation(videoRotationAngle: -90), .left)
  }

  func testOrientedVisionPointsMapBackToSensorCoordinates() {
    let point = NormalizedPoint(x: 0.2, y: 0.7)

    assertPoint(
      ScannerFrameOrientation.up.rawVisionPoint(fromOriented: point),
      equals: NormalizedPoint(x: 0.2, y: 0.7)
    )
    assertPoint(
      ScannerFrameOrientation.right.rawVisionPoint(fromOriented: point),
      equals: NormalizedPoint(x: 0.3, y: 0.2)
    )
    assertPoint(
      ScannerFrameOrientation.down.rawVisionPoint(fromOriented: point),
      equals: NormalizedPoint(x: 0.8, y: 0.3)
    )
    assertPoint(
      ScannerFrameOrientation.left.rawVisionPoint(fromOriented: point),
      equals: NormalizedPoint(x: 0.7, y: 0.8)
    )
  }

  private func assertPoint(
    _ actual: NormalizedPoint,
    equals expected: NormalizedPoint,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001, file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001, file: file, line: line)
  }

  private func candidate(offsetX: CGFloat, confidence: Float) -> RectangleCandidate {
    RectangleCandidate(
      quadrilateral: DocumentQuadrilateral(
        topLeft: NormalizedPoint(x: 0.18 + offsetX, y: 0.85),
        topRight: NormalizedPoint(x: 0.82 + offsetX, y: 0.84),
        bottomRight: NormalizedPoint(x: 0.8 + offsetX, y: 0.15),
        bottomLeft: NormalizedPoint(x: 0.2 + offsetX, y: 0.16)
      ),
      confidence: confidence
    )
  }

  private func syntheticBorderFillingBookSpread() -> CIImage {
    let extent = CGRect(x: 0, y: 0, width: 1_200, height: 900)
    let paper = CIImage(color: CIColor(red: 0.91, green: 0.90, blue: 0.86))
      .cropped(to: extent)
    let gutter = CIImage(color: CIColor(red: 0.47, green: 0.46, blue: 0.43))
      .cropped(to: CGRect(x: 770, y: 0, width: 28, height: 900))
    var image = gutter.composited(over: paper)

    for index in 0 ..< 12 {
      let y = 805 - CGFloat(index * 61)
      let leftLine = CIImage(color: CIColor(red: 0.36, green: 0.35, blue: 0.33))
        .cropped(
          to: CGRect(
            x: 95,
            y: y,
            width: 500 + CGFloat(index.isMultiple(of: 3) ? 80 : 0),
            height: 7
          )
        )
      let rightLine = CIImage(color: CIColor(red: 0.42, green: 0.41, blue: 0.39))
        .cropped(
          to: CGRect(
            x: 850,
            y: y - 8,
            width: 260 + CGFloat(index.isMultiple(of: 2) ? 35 : 0),
            height: 6
          )
        )
      image = rightLine.composited(over: leftLine.composited(over: image))
    }
    return image
  }
}

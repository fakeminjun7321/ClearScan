import CoreImage
import UIKit
import XCTest

@testable import ClearScan

/// Regression tests for clipped-page safety, multi-frame consensus, slow drift,
/// and the interface-orientation mapping used by the camera preview.
final class DetectionBehaviorUpgradeTests: XCTestCase {
  func testSuppressedCandidateNeverFillsRingOrBecomesStable() throws {
    var tracker = RectangleStabilityTracker()
    for index in 0...9 {
      let detection = try XCTUnwrap(
        tracker.update(
          candidate: pageCandidate(offsetX: 0, suppressesAutoCapture: true),
          timestamp: Double(index) * 0.1
        )
      )
      XCTAssertFalse(detection.isStable)
      XCTAssertTrue(detection.requiresRepositioning)
      XCTAssertEqual(detection.stabilityProgress, 0)
    }
  }

  func testOneSafeFrameCannotReuseSuppressedConsensus() throws {
    var tracker = RectangleStabilityTracker()
    for index in 0...7 {
      _ = tracker.update(
        candidate: pageCandidate(offsetX: 0, suppressesAutoCapture: true),
        timestamp: Double(index) * 0.1
      )
    }

    let safeCurrentFrame = try XCTUnwrap(
      tracker.update(
        candidate: pageCandidate(offsetX: 0),
        timestamp: 0.8
      )
    )

    XCTAssertFalse(safeCurrentFrame.isStable)
    XCTAssertTrue(safeCurrentFrame.requiresRepositioning)
    XCTAssertEqual(safeCurrentFrame.stabilityProgress, 0)
  }

  func testCleanConsensusBecomesStable() throws {
    var tracker = RectangleStabilityTracker()
    var finalDetection: LiveRectangleDetection?
    for index in 0...9 {
      finalDetection = tracker.update(
        candidate: pageCandidate(offsetX: 0),
        timestamp: Double(index) * 0.1
      )
    }
    let detection = try XCTUnwrap(finalDetection)
    XCTAssertTrue(detection.isStable)
    XCTAssertFalse(detection.requiresRepositioning)
    XCTAssertEqual(detection.stabilityProgress, 1)
  }

  func testSparseConsensusDoesNotAutoCapture() throws {
    var tracker = RectangleStabilityTracker()
    _ = tracker.update(candidate: pageCandidate(offsetX: 0), timestamp: 0)
    let final = try XCTUnwrap(
      tracker.update(candidate: pageCandidate(offsetX: 0), timestamp: 0.95)
    )
    XCTAssertFalse(final.isStable)
    XCTAssertLessThan(final.stabilityProgress, 1)
  }

  func testLongOutageResetsConsensus() throws {
    var tracker = RectangleStabilityTracker()
    for index in 0...2 {
      _ = tracker.update(
        candidate: pageCandidate(offsetX: 0),
        timestamp: Double(index) * 0.1
      )
    }
    for index in 3...8 {
      _ = tracker.update(candidate: nil, timestamp: Double(index) * 0.1)
    }
    let recovered = try XCTUnwrap(
      tracker.update(candidate: pageCandidate(offsetX: 0), timestamp: 0.9)
    )
    XCTAssertLessThanOrEqual(recovered.stabilityProgress, 0.2)
    XCTAssertFalse(recovered.isStable)
  }

  func testSlowDriftNeverCompletesRingOrBecomesStable() throws {
    var tracker = RectangleStabilityTracker()
    for index in 0...23 {
      let detection = tracker.update(
        candidate: narrowCandidate(offsetX: CGFloat(index) * 0.01),
        timestamp: Double(index) * 0.11
      )
      if let detection {
        XCTAssertFalse(detection.isStable)
        XCTAssertLessThan(detection.stabilityProgress, 1)
      }
    }
  }

  func testHandheldJitterStillBecomesStable() throws {
    var tracker = RectangleStabilityTracker()
    var finalDetection: LiveRectangleDetection?
    for index in 0...11 {
      let jitter: CGFloat = index.isMultiple(of: 2) ? 0.008 : -0.006
      finalDetection = tracker.update(
        candidate: pageCandidate(offsetX: index == 0 ? 0 : jitter),
        timestamp: Double(index) * 0.1
      )
    }
    XCTAssertTrue(try XCTUnwrap(finalDetection).isStable)
  }

  @MainActor
  func testInterfaceOrientationAngleMapping() {
    XCTAssertEqual(ScannerPreviewView.preferredVideoRotationAngle(for: .portrait), 90)
    XCTAssertEqual(ScannerPreviewView.preferredVideoRotationAngle(for: .portraitUpsideDown), 270)
    XCTAssertEqual(ScannerPreviewView.preferredVideoRotationAngle(for: .landscapeRight), 0)
    XCTAssertEqual(ScannerPreviewView.preferredVideoRotationAngle(for: .landscapeLeft), 180)
    XCTAssertEqual(ScannerPreviewView.preferredVideoRotationAngle(for: .unknown), 90)
  }

  private func pageCandidate(
    offsetX: CGFloat,
    suppressesAutoCapture: Bool = false
  ) -> RectangleCandidate {
    RectangleCandidate(
      quadrilateral: DocumentQuadrilateral(
        topLeft: NormalizedPoint(x: 0.18 + offsetX, y: 0.85),
        topRight: NormalizedPoint(x: 0.82 + offsetX, y: 0.84),
        bottomRight: NormalizedPoint(x: 0.8 + offsetX, y: 0.15),
        bottomLeft: NormalizedPoint(x: 0.2 + offsetX, y: 0.16)
      ),
      confidence: 0.8,
      suppressesAutoCapture: suppressesAutoCapture
    )
  }

  private func narrowCandidate(offsetX: CGFloat) -> RectangleCandidate {
    RectangleCandidate(
      quadrilateral: DocumentQuadrilateral(
        topLeft: NormalizedPoint(x: 0.10 + offsetX, y: 0.8),
        topRight: NormalizedPoint(x: 0.48 + offsetX, y: 0.8),
        bottomRight: NormalizedPoint(x: 0.48 + offsetX, y: 0.2),
        bottomLeft: NormalizedPoint(x: 0.10 + offsetX, y: 0.2)
      ),
      confidence: 0.8
    )
  }
}

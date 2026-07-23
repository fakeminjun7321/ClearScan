import XCTest

@testable import ClearScan

final class ConservativeFingerRemoverTests: XCTestCase {
  private let policy = ConservativeFingerCandidatePolicy()

  func testAcceptsSmallForegroundOnlyWhenItTouchesEdge() throws {
    let selected = try policy.selectedInstances(
      from: [
        ForegroundInstanceCandidate(instanceID: 1, areaRatio: 0.04, touchesImageEdge: true),
        ForegroundInstanceCandidate(instanceID: 2, areaRatio: 0.03, touchesImageEdge: false),
      ],
      hasHandEvidence: false
    )

    XCTAssertEqual(selected, IndexSet(integer: 1))
  }

  func testMediumCandidateRequiresHandEvidence() {
    let candidate = ForegroundInstanceCandidate(
      instanceID: 3,
      areaRatio: 0.12,
      touchesImageEdge: true
    )

    XCTAssertThrowsError(
      try policy.selectedInstances(from: [candidate], hasHandEvidence: false)
    ) { error in
      XCTAssertEqual(error as? ConservativeFingerRemovalError, .noConservativeCandidate)
    }
    XCTAssertEqual(
      try policy.selectedInstances(from: [candidate], hasHandEvidence: true),
      IndexSet(integer: 3)
    )
  }

  func testRejectsPageSizedMaskEvenWithHandEvidence() {
    let pageMask = ForegroundInstanceCandidate(
      instanceID: 1,
      areaRatio: 0.82,
      touchesImageEdge: true
    )

    XCTAssertThrowsError(
      try policy.selectedInstances(from: [pageMask], hasHandEvidence: true)
    ) { error in
      XCTAssertEqual(error as? ConservativeFingerRemovalError, .noConservativeCandidate)
    }
  }

  func testRejectsCombinedCandidatesOverSafetyLimit() {
    let candidates = [
      ForegroundInstanceCandidate(instanceID: 1, areaRatio: 0.10, touchesImageEdge: true),
      ForegroundInstanceCandidate(instanceID: 2, areaRatio: 0.09, touchesImageEdge: true),
    ]

    XCTAssertThrowsError(
      try policy.selectedInstances(from: candidates, hasHandEvidence: true)
    ) { error in
      XCTAssertEqual(error as? ConservativeFingerRemovalError, .combinedCandidateAreaTooLarge)
    }
  }
}

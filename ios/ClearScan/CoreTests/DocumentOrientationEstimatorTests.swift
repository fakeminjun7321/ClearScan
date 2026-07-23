import XCTest

@testable import ClearScan

final class DocumentOrientationEstimatorTests: XCTestCase {
  func testChoosesOrientationWithStrongTextEvidence() {
    let result = DocumentOrientationEstimator.result(from: [
      candidate(.up, lines: 1, characters: 5, confidence: 0.4),
      candidate(.right, lines: 8, characters: 80, confidence: 0.92),
      candidate(.down, lines: 2, characters: 10, confidence: 0.5),
      candidate(.left, lines: 1, characters: 6, confidence: 0.3),
    ])

    XCTAssertEqual(result.recommendedOrientation, .right)
    XCTAssertTrue(result.isReliable)
    XCTAssertGreaterThan(result.confidence, 0.1)
  }

  func testFallsBackToUpWhenEvidenceIsAmbiguous() {
    let result = DocumentOrientationEstimator.result(from: [
      candidate(.up, lines: 5, characters: 40, confidence: 0.80),
      candidate(.right, lines: 5, characters: 40, confidence: 0.78),
    ])

    XCTAssertEqual(result.recommendedOrientation, .up)
    XCTAssertFalse(result.isReliable)
  }

  func testBlankImageDoesNotRecommendDestructiveRotation() throws {
    let blank = try grayscaleImage(width: 80, height: 120) { _, _ in 255 }

    let result = try DocumentOrientationEstimator().estimateOrientation(in: blank)

    XCTAssertEqual(result.recommendedOrientation, .up)
    XCTAssertFalse(result.isReliable)
  }

  private func candidate(
    _ orientation: DocumentOrientation,
    lines: Int,
    characters: Int,
    confidence: Float
  ) -> DocumentOrientationCandidateScore {
    DocumentOrientationCandidateScore(
      orientation: orientation,
      recognizedLineCount: lines,
      recognizedCharacterCount: characters,
      averageConfidence: confidence
    )
  }
}

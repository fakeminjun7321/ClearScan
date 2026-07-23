import CoreGraphics
import UIKit
import XCTest

@testable import ClearScan

final class OnDeviceDocumentAIEnsembleTests: XCTestCase {
  private let box = CGRect(x: 0.1, y: 0.72, width: 0.72, height: 0.1)

  func testThreePassExactConsensusCanReplaceLowConfidenceOriginal() {
    let outcome = OnDeviceDocumentAI.fuse([
      pass(.original, text: "Clear5can", confidence: 0.18),
      pass(.illuminationNormalized, text: "ClearScan", confidence: 0.82),
      pass(.highContrastBlackAndWhite, text: "ClearScan", confidence: 0.79),
      pass(.conservativeSharpen, text: "ClearScan", confidence: 0.84),
    ])

    XCTAssertEqual(outcome.lines.map(\.text), ["ClearScan"])
    XCTAssertEqual(
      outcome.usedPasses,
      [.illuminationNormalized, .highContrastBlackAndWhite, .conservativeSharpen]
    )
    XCTAssertEqual(outcome.averageAgreement, 0.75, accuracy: 0.001)
  }

  func testSingleProcessedPassCannotOverrideOriginalEvenAtHighConfidence() {
    let outcome = OnDeviceDocumentAI.fuse([
      pass(.original, text: "문서 번호 123", confidence: 0.31),
      pass(.conservativeSharpen, text: "문서 번호 I23", confidence: 0.98),
    ])

    XCTAssertEqual(outcome.lines.map(\.text), ["문서 번호 123"])
    XCTAssertEqual(outcome.usedPasses, [.original])
    XCTAssertEqual(outcome.originalFallbackLineCount, 1)
  }

  func testAgreementPreservesExactOriginalCandidateInsteadOfSynthesizingText() {
    let outcome = OnDeviceDocumentAI.fuse([
      pass(.original, text: "ClearScan  OCR", confidence: 0.73),
      pass(.illuminationNormalized, text: "ClearScan OCR", confidence: 0.76),
      pass(.highContrastBlackAndWhite, text: "ClearScan OCR", confidence: 0.78),
    ])

    XCTAssertEqual(outcome.lines.map(\.text), ["ClearScan  OCR"])
    XCTAssertEqual(
      outcome.usedPasses,
      [.original, .illuminationNormalized, .highContrastBlackAndWhite]
    )
  }

  func testConsensusMaySelectOnlyAnActuallyObservedLowerRankCandidate() {
    let original = DocumentOCRPassResult(
      pass: .original,
      observations: [
        DocumentOCRPassObservation(
          candidates: [
            DocumentOCRCandidate(text: "Clear5can", confidence: 0.5, rank: 0),
            DocumentOCRCandidate(text: "ClearScan", confidence: 0.48, rank: 1),
          ],
          boundingBox: box
        )
      ]
    )
    let outcome = OnDeviceDocumentAI.fuse([
      original,
      pass(.illuminationNormalized, text: "ClearScan", confidence: 0.8),
      pass(.highContrastBlackAndWhite, text: "ClearScan", confidence: 0.78),
    ])

    XCTAssertEqual(outcome.lines.map(\.text), ["ClearScan"])
    XCTAssertEqual(
      outcome.usedPasses,
      [.original, .illuminationNormalized, .highContrastBlackAndWhite]
    )
  }

  func testUnconfirmedTransformedOnlyLineIsDropped() {
    let original = pass(.original, text: "첫 번째 줄", confidence: 0.88)
    let unconfirmed = DocumentOCRPassResult(
      pass: .conservativeSharpen,
      observations: [
        observation(
          text: "추정된 새 문장",
          confidence: 0.99,
          box: CGRect(x: 0.1, y: 0.48, width: 0.7, height: 0.09)
        )
      ]
    )

    let outcome = OnDeviceDocumentAI.fuse([original, unconfirmed])

    XCTAssertEqual(outcome.lines.map(\.text), ["첫 번째 줄"])
  }

  func testTransformedOnlyLineRequiresTwoExactCandidatesAndKeepsReadingOrder() {
    let lowerBox = CGRect(x: 0.1, y: 0.44, width: 0.72, height: 0.09)
    let outcome = OnDeviceDocumentAI.fuse([
      pass(.original, text: "첫 번째 줄", confidence: 0.9),
      DocumentOCRPassResult(
        pass: .illuminationNormalized,
        observations: [
          observation(text: "작은 글자 ABC 123", confidence: 0.76, box: lowerBox)
        ]
      ),
      DocumentOCRPassResult(
        pass: .highContrastBlackAndWhite,
        observations: [
          observation(text: "작은 글자 ABC 123", confidence: 0.72, box: lowerBox)
        ]
      ),
    ])

    XCTAssertEqual(outcome.lines.map(\.text), ["첫 번째 줄", "작은 글자 ABC 123"])
  }

  func testLargeCameraImagePreparationHasBoundedPixelMemory() {
    let dimensions = OnDeviceDocumentAI.boundedDimensions(
      width: 12_000,
      height: 9_000,
      maximumDimension: OnDeviceDocumentAI.defaultMaximumOCRDimension
    )
    let maximum = OnDeviceDocumentAI.defaultMaximumOCRDimension
    let estimatedRGBABytes = dimensions.width * dimensions.height * 4

    XCTAssertEqual(dimensions.width, 2_200)
    XCTAssertEqual(dimensions.height, 1_650)
    XCTAssertLessThanOrEqual(estimatedRGBABytes, maximum * maximum * 4)
  }

  func testRenderedKoreanEnglishTextSmokeWithinProcessingBudget() throws {
    let image = try renderedTextFixture()
    let ai = OnDeviceDocumentAI(
      maximumOCRDimension: 1_800,
      processingTimeLimit: 18
    )
    let start = ProcessInfo.processInfo.systemUptime

    let result = try ai.recognizeText(in: image)

    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let normalizedText = result.text
      .lowercased()
      .filter(\.isLetter)
    XCTAssertTrue(
      normalizedText.contains("clearscan"),
      "Expected ClearScan text in: \(result.text)"
    )
    XCTAssertTrue(
      result.text.contains("문서") || result.text.contains("스캔"),
      "Expected Korean text in: \(result.text)"
    )
    XCTAssertTrue(result.text.contains("123"), "Expected small text in: \(result.text)")
    XCTAssertEqual(result.attemptedPasses, DocumentOCRPass.allCases)
    XCTAssertLessThanOrEqual(result.usedPasses.count, DocumentOCRPass.allCases.count)
    XCTAssertLessThan(elapsed, 20)
  }

  private func pass(
    _ pass: DocumentOCRPass,
    text: String,
    confidence: Float
  ) -> DocumentOCRPassResult {
    DocumentOCRPassResult(
      pass: pass,
      observations: [
        observation(text: text, confidence: confidence, box: box)
      ]
    )
  }

  private func observation(
    text: String,
    confidence: Float,
    box: CGRect
  ) -> DocumentOCRPassObservation {
    DocumentOCRPassObservation(
      candidates: [
        DocumentOCRCandidate(text: text, confidence: confidence, rank: 0)
      ],
      boundingBox: box
    )
  }

  private func renderedTextFixture() throws -> CGImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: 1_600, height: 1_100),
      format: format
    )
    let image = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 1_100))

      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .left
      ("문서 스캔 테스트" as NSString).draw(
        at: CGPoint(x: 120, y: 150),
        withAttributes: [
          .font: UIFont.systemFont(ofSize: 76, weight: .semibold),
          .foregroundColor: UIColor.black,
          .paragraphStyle: paragraph,
        ]
      )
      ("ClearScan OCR 2026" as NSString).draw(
        at: CGPoint(x: 120, y: 350),
        withAttributes: [
          .font: UIFont.systemFont(ofSize: 68, weight: .medium),
          .foregroundColor: UIColor.black,
          .paragraphStyle: paragraph,
        ]
      )
      ("작은 글자 ABC 123" as NSString).draw(
        at: CGPoint(x: 120, y: 570),
        withAttributes: [
          .font: UIFont.systemFont(ofSize: 30, weight: .regular),
          .foregroundColor: UIColor.darkGray,
          .paragraphStyle: paragraph,
        ]
      )
    }
    return try XCTUnwrap(image.cgImage)
  }
}

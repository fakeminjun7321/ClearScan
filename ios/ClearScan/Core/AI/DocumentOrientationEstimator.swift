import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum DocumentOrientation: String, CaseIterable, Equatable, Sendable {
  case up
  case right
  case down
  case left

  public var imagePropertyOrientation: CGImagePropertyOrientation {
    switch self {
    case .up: .up
    case .right: .right
    case .down: .down
    case .left: .left
    }
  }
}

public struct DocumentOrientationCandidateScore: Equatable, Sendable {
  public let orientation: DocumentOrientation
  public let recognizedLineCount: Int
  public let recognizedCharacterCount: Int
  public let averageConfidence: Float

  public init(
    orientation: DocumentOrientation,
    recognizedLineCount: Int,
    recognizedCharacterCount: Int,
    averageConfidence: Float
  ) {
    self.orientation = orientation
    self.recognizedLineCount = recognizedLineCount
    self.recognizedCharacterCount = recognizedCharacterCount
    self.averageConfidence = averageConfidence
  }

  public var score: Double {
    guard recognizedLineCount > 0, recognizedCharacterCount > 0 else { return 0 }
    let usefulCharacters = min(max(recognizedCharacterCount, 0), 240)
    return Double(averageConfidence)
      * (log1p(Double(usefulCharacters)) + 0.35 * Double(recognizedLineCount))
  }
}

public struct DocumentOrientationResult: Equatable, Sendable {
  public let recommendedOrientation: DocumentOrientation
  public let confidence: Double
  public let isReliable: Bool
  public let candidates: [DocumentOrientationCandidateScore]

  public init(
    recommendedOrientation: DocumentOrientation,
    confidence: Double,
    isReliable: Bool,
    candidates: [DocumentOrientationCandidateScore]
  ) {
    self.recommendedOrientation = recommendedOrientation
    self.confidence = confidence
    self.isReliable = isReliable
    self.candidates = candidates
  }
}

/// Tests all four right-angle orientations with Vision's fast, fully
/// on-device OCR. It recommends a rotation only when there is enough text and
/// a meaningful score margin, avoiding destructive guesses on blank pages.
public final class DocumentOrientationEstimator: Sendable {
  public init() {}

  public func estimateOrientation(in image: CGImage) throws -> DocumentOrientationResult {
    let candidates = try DocumentOrientation.allCases.map { orientation in
      try score(image: image, orientation: orientation)
    }
    return Self.result(from: candidates)
  }

  static func result(
    from candidates: [DocumentOrientationCandidateScore]
  ) -> DocumentOrientationResult {
    let order = Dictionary(
      uniqueKeysWithValues: DocumentOrientation.allCases.enumerated().map { ($1, $0) }
    )
    let sorted = candidates.sorted { lhs, rhs in
      if lhs.score == rhs.score {
        return (order[lhs.orientation] ?? 0) < (order[rhs.orientation] ?? 0)
      }
      return lhs.score > rhs.score
    }
    guard let best = sorted.first else {
      return DocumentOrientationResult(
        recommendedOrientation: .up,
        confidence: 0,
        isReliable: false,
        candidates: []
      )
    }

    let runnerUpScore = sorted.dropFirst().first?.score ?? 0
    let margin = best.score > 0 ? (best.score - runnerUpScore) / best.score : 0
    let reliable =
      best.recognizedCharacterCount >= 4
      && best.averageConfidence >= 0.35
      && best.score >= 0.8
      && margin >= 0.10

    return DocumentOrientationResult(
      recommendedOrientation: reliable ? best.orientation : .up,
      confidence: min(max(margin, 0), 1),
      isReliable: reliable,
      candidates: candidates
    )
  }

  private func score(
    image: CGImage,
    orientation: DocumentOrientation
  ) throws -> DocumentOrientationCandidateScore {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.recognitionLanguages = ["ko-KR", "en-US"]
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.012

    let handler = VNImageRequestHandler(
      cgImage: image,
      orientation: orientation.imagePropertyOrientation
    )
    try handler.perform([request])

    let candidates = (request.results ?? []).compactMap {
      $0.topCandidates(1).first
    }
    let characterCount = candidates.reduce(0) {
      $0 + $1.string.filter { !$0.isWhitespace }.count
    }
    let averageConfidence = candidates.isEmpty
      ? 0
      : candidates.reduce(Float.zero) { $0 + $1.confidence } / Float(candidates.count)

    return DocumentOrientationCandidateScore(
      orientation: orientation,
      recognizedLineCount: candidates.count,
      recognizedCharacterCount: characterCount,
      averageConfidence: averageConfidence
    )
  }
}

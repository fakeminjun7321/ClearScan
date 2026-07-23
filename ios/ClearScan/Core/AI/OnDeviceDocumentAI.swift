import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Vision

public enum DocumentOCRPass: String, CaseIterable, Sendable {
  case original
  case illuminationNormalized
  case highContrastBlackAndWhite
  case conservativeSharpen

  fileprivate var order: Int {
    switch self {
    case .original: 0
    case .illuminationNormalized: 1
    case .highContrastBlackAndWhite: 2
    case .conservativeSharpen: 3
    }
  }
}

public struct DocumentOCRResult: Equatable, Sendable {
  public let text: String
  public let averageConfidence: Float
  public let suggestedTitle: String?

  /// Passes that produced the exact candidates selected for the final text.
  public let usedPasses: [DocumentOCRPass]

  /// Passes that started within the bounded processing window.
  public let attemptedPasses: [DocumentOCRPass]

  /// Average exact-candidate agreement from 0...1 across all four intended passes.
  public let ensembleAgreement: Float

  /// Low-confidence original lines kept because no safe multi-pass consensus existed.
  public let originalFallbackLineCount: Int

  public init(
    text: String,
    averageConfidence: Float,
    suggestedTitle: String?,
    usedPasses: [DocumentOCRPass] = [],
    attemptedPasses: [DocumentOCRPass] = [],
    ensembleAgreement: Float = 0,
    originalFallbackLineCount: Int = 0
  ) {
    self.text = text
    self.averageConfidence = averageConfidence
    self.suggestedTitle = suggestedTitle
    self.usedPasses = usedPasses
    self.attemptedPasses = attemptedPasses
    self.ensembleAgreement = ensembleAgreement
    self.originalFallbackLineCount = originalFallbackLineCount
  }
}

public enum DocumentAIError: LocalizedError {
  case noTextFound
  case imageProcessingFailed

  public var errorDescription: String? {
    switch self {
    case .noTextFound:
      return "이 페이지에서 읽을 수 있는 글자를 찾지 못했습니다."
    case .imageProcessingFailed:
      return "문서 이미지를 판독할 수 있는 크기로 준비하지 못했습니다."
    }
  }
}

struct DocumentOCRLine: Equatable, Sendable {
  let text: String
  let confidence: Float
  let boundingBox: CGRect
}

struct DocumentOCRCandidate: Equatable, Sendable {
  let text: String
  let confidence: Float
  let rank: Int
}

struct DocumentOCRPassObservation: Equatable, Sendable {
  let candidates: [DocumentOCRCandidate]
  let boundingBox: CGRect
}

struct DocumentOCRPassResult: Equatable, Sendable {
  let pass: DocumentOCRPass
  let observations: [DocumentOCRPassObservation]
}

struct DocumentOCRFusionOutcome: Equatable, Sendable {
  let lines: [DocumentOCRLine]
  let usedPasses: [DocumentOCRPass]
  let averageAgreement: Float
  let originalFallbackLineCount: Int
}

private struct LocatedOCRObservation {
  let pass: DocumentOCRPass
  let observation: DocumentOCRPassObservation
}

private struct OCRObservationCluster {
  var observations: [LocatedOCRObservation]
  var averageBox: CGRect

  mutating func append(_ located: LocatedOCRObservation) {
    let count = CGFloat(observations.count)
    let box = located.observation.boundingBox
    averageBox = CGRect(
      x: (averageBox.minX * count + box.minX) / (count + 1),
      y: (averageBox.minY * count + box.minY) / (count + 1),
      width: (averageBox.width * count + box.width) / (count + 1),
      height: (averageBox.height * count + box.height) / (count + 1)
    )
    observations.append(located)
  }
}

private struct OCRCandidateSupport {
  let pass: DocumentOCRPass
  let candidate: DocumentOCRCandidate
  let boundingBox: CGRect

  var adjustedConfidence: Float {
    max(0, candidate.confidence - Float(candidate.rank) * 0.045)
  }
}

private struct OCRCandidateGroup {
  let key: String
  let supports: [OCRCandidateSupport]

  var averageConfidence: Float {
    supports.reduce(Float.zero) { $0 + $1.adjustedConfidence }
      / Float(max(supports.count, 1))
  }

  var score: Float {
    let agreementBonus = Float(max(supports.count - 1, 0)) * 0.08
    let originalBonus: Float =
      supports.contains {
        $0.pass == .original && $0.candidate.rank == 0
      } ? 0.06 : 0
    return averageConfidence + agreementBonus + originalBonus
  }

  var containsOriginalTopCandidate: Bool {
    supports.contains { $0.pass == .original && $0.candidate.rank == 0 }
  }
}

/// Stateless wrapper around Apple's on-device Vision text recognizer. No image
/// or recognized text leaves the device through this service.
///
/// The four-pass strategy is an independent implementation based only on the
/// general idea of comparing multiple image readings. It does not include,
/// copy, link, or call Quilo code or services.
public final class OnDeviceDocumentAI: @unchecked Sendable {
  public static let defaultMaximumOCRDimension = 2_200
  public static let maximumSupportedOCRDimension = 2_600
  public static let defaultProcessingTimeLimit: TimeInterval = 12
  public static let maximumSupportedProcessingTimeLimit: TimeInterval = 20

  private let maximumOCRDimension: Int
  private let processingTimeLimit: TimeInterval
  private let context: CIContext
  private let outputColorSpace =
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  public init(
    maximumOCRDimension: Int = OnDeviceDocumentAI.defaultMaximumOCRDimension,
    processingTimeLimit: TimeInterval = OnDeviceDocumentAI.defaultProcessingTimeLimit
  ) {
    self.maximumOCRDimension = min(
      max(maximumOCRDimension, 640),
      Self.maximumSupportedOCRDimension
    )
    self.processingTimeLimit = min(
      max(processingTimeLimit, 1),
      Self.maximumSupportedProcessingTimeLimit
    )
    context = CIContext(options: [
      .cacheIntermediates: false,
      .useSoftwareRenderer: false,
    ])
  }

  public func recognizeText(
    in image: CGImage,
    orientation: CGImagePropertyOrientation = .up
  ) throws -> DocumentOCRResult {
    let startedAt = ProcessInfo.processInfo.systemUptime
    let boundedImage = try boundedImage(image)
    var attemptedPasses: [DocumentOCRPass] = []
    var passResults: [DocumentOCRPassResult] = []

    for pass in DocumentOCRPass.allCases {
      if pass != .original,
        ProcessInfo.processInfo.systemUptime - startedAt >= processingTimeLimit
      {
        break
      }

      attemptedPasses.append(pass)
      do {
        let observations: [DocumentOCRPassObservation] = try autoreleasepool {
          let passImage = try preparedImage(for: pass, source: boundedImage)
          return try recognizeObservations(
            in: passImage,
            orientation: orientation,
            deadline: pass == .original ? nil : startedAt + processingTimeLimit
          )
        }
        passResults.append(
          DocumentOCRPassResult(pass: pass, observations: observations)
        )
      } catch {
        if pass == .original {
          throw error
        }
      }
    }

    let fusion = Self.fuse(passResults)
    guard !fusion.lines.isEmpty else { throw DocumentAIError.noTextFound }

    let confidence =
      fusion.lines.reduce(Float.zero) { $0 + $1.confidence }
      / Float(fusion.lines.count)
    let lines = fusion.lines.map(\.text)
    return DocumentOCRResult(
      text: lines.joined(separator: "\n"),
      averageConfidence: confidence,
      suggestedTitle: Self.suggestedTitle(from: lines),
      usedPasses: fusion.usedPasses,
      attemptedPasses: attemptedPasses,
      ensembleAgreement: fusion.averageAgreement,
      originalFallbackLineCount: fusion.originalFallbackLineCount
    )
  }

  public static func suggestedTitle(from lines: [String]) -> String? {
    lines.lazy
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
      .map { String($0.prefix(48)) }
  }

  static func boundedDimensions(
    width: Int,
    height: Int,
    maximumDimension: Int
  ) -> (width: Int, height: Int) {
    let safeWidth = max(width, 1)
    let safeHeight = max(height, 1)
    let safeMaximum = max(maximumDimension, 1)
    let longest = max(safeWidth, safeHeight)
    guard longest > safeMaximum else {
      return (safeWidth, safeHeight)
    }
    let scale = Double(safeMaximum) / Double(longest)
    return (
      max(Int((Double(safeWidth) * scale).rounded()), 1),
      max(Int((Double(safeHeight) * scale).rounded()), 1)
    )
  }

  static func fuse(
    _ passResults: [DocumentOCRPassResult]
  ) -> DocumentOCRFusionOutcome {
    var clusters: [OCRObservationCluster] = []
    let orderedResults = passResults.sorted { $0.pass.order < $1.pass.order }

    for result in orderedResults {
      for observation in result.observations where !observation.candidates.isEmpty {
        let located = LocatedOCRObservation(
          pass: result.pass,
          observation: observation
        )
        var bestIndex: Int?
        var bestSimilarity: CGFloat = 0

        for index in clusters.indices
        where !clusters[index].observations.contains(where: {
          $0.pass == result.pass
        }) {
          let similarity = positionalSimilarity(
            observation.boundingBox,
            clusters[index].averageBox
          )
          if similarity > bestSimilarity {
            bestSimilarity = similarity
            bestIndex = index
          }
        }

        if let bestIndex, bestSimilarity >= 0.42 {
          clusters[bestIndex].append(located)
        } else {
          clusters.append(
            OCRObservationCluster(
              observations: [located],
              averageBox: observation.boundingBox
            )
          )
        }
      }
    }

    var selectedLines: [DocumentOCRLine] = []
    var usedPassSet = Set<DocumentOCRPass>()
    var agreements: [Float] = []
    var fallbackLineCount = 0

    for cluster in clusters {
      let groups = candidateGroups(in: cluster)
      guard let selection = safestGroup(from: groups) else { continue }
      let renderedSupport =
        selection.supports.first { $0.pass == .original }
        ?? selection.supports.max {
          if $0.candidate.confidence == $1.candidate.confidence {
            return $0.candidate.rank > $1.candidate.rank
          }
          return $0.candidate.confidence < $1.candidate.confidence
        }
      guard let renderedSupport else { continue }

      let agreement =
        Float(selection.supports.count)
        / Float(DocumentOCRPass.allCases.count)
      let fusedConfidence = min(
        1,
        selection.averageConfidence
          + Float(max(selection.supports.count - 1, 0)) * 0.035
      )
      selectedLines.append(
        DocumentOCRLine(
          text: renderedSupport.candidate.text,
          confidence: fusedConfidence,
          boundingBox: renderedSupport.boundingBox
        )
      )
      agreements.append(agreement)
      for support in selection.supports {
        usedPassSet.insert(support.pass)
      }

      if selection.containsOriginalTopCandidate,
        selection.supports.count == 1,
        selection.averageConfidence < 0.62
      {
        fallbackLineCount += 1
      }
    }

    let averageAgreement =
      agreements.isEmpty
      ? 0
      : agreements.reduce(Float.zero, +) / Float(agreements.count)
    return DocumentOCRFusionOutcome(
      lines: linesInReadingOrder(selectedLines),
      usedPasses: DocumentOCRPass.allCases.filter(usedPassSet.contains),
      averageAgreement: averageAgreement,
      originalFallbackLineCount: fallbackLineCount
    )
  }

  /// Vision uses a lower-left origin and does not promise that observations
  /// arrive in reading order. Group neighboring observations into rows first,
  /// then read each row from left to right.
  static func linesInReadingOrder(_ lines: [DocumentOCRLine]) -> [DocumentOCRLine] {
    struct Row {
      var lines: [DocumentOCRLine]
      var centerY: CGFloat
      var averageHeight: CGFloat

      mutating func append(_ line: DocumentOCRLine) {
        let count = CGFloat(lines.count)
        centerY = (centerY * count + line.boundingBox.midY) / (count + 1)
        averageHeight = (averageHeight * count + line.boundingBox.height) / (count + 1)
        lines.append(line)
      }
    }

    let verticalOrder = lines.sorted { lhs, rhs in
      if lhs.boundingBox.midY == rhs.boundingBox.midY {
        return lhs.boundingBox.minX < rhs.boundingBox.minX
      }
      return lhs.boundingBox.midY > rhs.boundingBox.midY
    }

    var rows: [Row] = []
    for line in verticalOrder {
      if var row = rows.last {
        let threshold = max(row.averageHeight, line.boundingBox.height) * 0.6
        if abs(row.centerY - line.boundingBox.midY) <= threshold {
          row.append(line)
          rows[rows.count - 1] = row
          continue
        }
      }
      rows.append(
        Row(
          lines: [line],
          centerY: line.boundingBox.midY,
          averageHeight: line.boundingBox.height
        )
      )
    }

    return rows.flatMap { row in
      row.lines.sorted { lhs, rhs in
        lhs.boundingBox.minX < rhs.boundingBox.minX
      }
    }
  }

  private func recognizeObservations(
    in image: CGImage,
    orientation: CGImagePropertyOrientation,
    deadline: TimeInterval?
  ) throws -> [DocumentOCRPassObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ko-KR", "en-US"]
    request.automaticallyDetectsLanguage = true
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.0035
    if let deadline {
      request.progressHandler = { request, _, _ in
        if ProcessInfo.processInfo.systemUptime >= deadline {
          request.cancel()
        }
      }
    }

    let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
    try handler.perform([request])

    return (request.results ?? []).compactMap { observation in
      var seenKeys = Set<String>()
      let candidates = observation.topCandidates(3).enumerated().compactMap {
        rank,
        candidate -> DocumentOCRCandidate? in
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let key = Self.matchingKey(for: text)
        guard seenKeys.insert(key).inserted else { return nil }
        return DocumentOCRCandidate(
          text: text,
          confidence: candidate.confidence,
          rank: rank
        )
      }
      guard !candidates.isEmpty else { return nil }
      return DocumentOCRPassObservation(
        candidates: candidates,
        boundingBox: observation.boundingBox
      )
    }
  }

  private func boundedImage(_ image: CGImage) throws -> CGImage {
    let dimensions = Self.boundedDimensions(
      width: image.width,
      height: image.height,
      maximumDimension: maximumOCRDimension
    )
    guard dimensions.width != image.width || dimensions.height != image.height else {
      return image
    }

    let source = CIImage(cgImage: image)
    let scale = CGFloat(dimensions.width) / CGFloat(image.width)
    let filter = CIFilter.lanczosScaleTransform()
    filter.inputImage = source
    filter.scale = Float(scale)
    filter.aspectRatio = 1
    guard let output = filter.outputImage else {
      throw DocumentAIError.imageProcessingFailed
    }
    return try renderedImage(output.translatedForOCRToOrigin())
  }

  private func preparedImage(
    for pass: DocumentOCRPass,
    source: CGImage
  ) throws -> CGImage {
    switch pass {
    case .original:
      return source

    case .illuminationNormalized:
      return try DocumentIlluminationNormalizer().normalizedImage(
        source,
        strength: 0.72
      )

    case .highContrastBlackAndWhite:
      let image = CIImage(cgImage: source).translatedForOCRToOrigin()
      let controls = CIFilter.colorControls()
      controls.inputImage = image
      controls.saturation = 0
      controls.contrast = 1.32
      controls.brightness = 0.025

      let exposure = CIFilter.exposureAdjust()
      exposure.inputImage = controls.outputImage ?? image
      exposure.ev = 0.08
      return try renderedImage(
        (exposure.outputImage ?? controls.outputImage ?? image)
          .cropped(to: image.extent)
      )

    case .conservativeSharpen:
      let image = CIImage(cgImage: source).translatedForOCRToOrigin()
      let denoise = CIFilter.noiseReduction()
      denoise.inputImage = image
      denoise.noiseLevel = 0.006
      denoise.sharpness = 0.18

      let unsharp = CIFilter.unsharpMask()
      unsharp.inputImage = denoise.outputImage ?? image
      unsharp.radius = 0.78
      unsharp.intensity = 0.34

      let luminance = CIFilter.sharpenLuminance()
      luminance.inputImage = unsharp.outputImage ?? denoise.outputImage ?? image
      luminance.sharpness = 0.16
      return try renderedImage(
        (luminance.outputImage ?? unsharp.outputImage ?? image)
          .cropped(to: image.extent)
      )
    }
  }

  private func renderedImage(_ image: CIImage) throws -> CGImage {
    let extent = image.extent.integral
    guard !extent.isEmpty,
      let rendered = context.createCGImage(
        image,
        from: extent,
        format: .RGBA8,
        colorSpace: outputColorSpace
      )
    else {
      throw DocumentAIError.imageProcessingFailed
    }
    return rendered
  }

  private static func candidateGroups(
    in cluster: OCRObservationCluster
  ) -> [OCRCandidateGroup] {
    var grouped: [String: [DocumentOCRPass: OCRCandidateSupport]] = [:]
    for located in cluster.observations {
      for candidate in located.observation.candidates {
        let key = matchingKey(for: candidate.text)
        let support = OCRCandidateSupport(
          pass: located.pass,
          candidate: candidate,
          boundingBox: located.observation.boundingBox
        )
        let existing = grouped[key]?[located.pass]
        if existing == nil || support.adjustedConfidence > existing!.adjustedConfidence {
          grouped[key, default: [:]][located.pass] = support
        }
      }
    }

    return grouped.map { key, passSupports in
      OCRCandidateGroup(
        key: key,
        supports: passSupports.values.sorted {
          if $0.pass.order == $1.pass.order {
            return $0.candidate.rank < $1.candidate.rank
          }
          return $0.pass.order < $1.pass.order
        }
      )
    }
  }

  private static func safestGroup(
    from groups: [OCRCandidateGroup]
  ) -> OCRCandidateGroup? {
    let baseline = groups.first(where: \.containsOriginalTopCandidate)
    guard let baseline else {
      return
        groups
        .filter { $0.supports.count >= 2 && $0.averageConfidence >= 0.55 }
        .sorted(by: groupIsSafer)
        .first
    }

    let challenger =
      groups
      .filter {
        $0.key != baseline.key
          && $0.supports.count >= 2
          && $0.averageConfidence >= 0.45
      }
      .sorted(by: groupIsSafer)
      .first
    guard let challenger else { return baseline }

    let requiredMargin: Float = challenger.supports.count >= 3 ? 0.02 : 0.10
    let confidenceFloor =
      challenger.supports.count >= 3
      ? max(0.45, baseline.averageConfidence - 0.03)
      : max(0.45, baseline.averageConfidence + 0.02)
    guard challenger.score >= baseline.score + requiredMargin,
      challenger.averageConfidence >= confidenceFloor
    else {
      return baseline
    }
    return challenger
  }

  private static func groupIsSafer(
    _ lhs: OCRCandidateGroup,
    _ rhs: OCRCandidateGroup
  ) -> Bool {
    if abs(lhs.score - rhs.score) > 0.0001 {
      return lhs.score > rhs.score
    }
    if lhs.supports.count != rhs.supports.count {
      return lhs.supports.count > rhs.supports.count
    }
    return lhs.key < rhs.key
  }

  private static func matchingKey(for text: String) -> String {
    text.precomposedStringWithCanonicalMapping
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func positionalSimilarity(
    _ lhs: CGRect,
    _ rhs: CGRect
  ) -> CGFloat {
    guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else {
      return 0
    }
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, !intersection.isEmpty else { return 0 }

    let verticalOverlap = intersection.height / min(lhs.height, rhs.height)
    let horizontalOverlap = intersection.width / min(lhs.width, rhs.width)
    guard verticalOverlap >= 0.38, horizontalOverlap >= 0.22 else { return 0 }

    let normalizedXDistance =
      abs(lhs.midX - rhs.midX) / max(lhs.width, rhs.width)
    let normalizedYDistance =
      abs(lhs.midY - rhs.midY) / max(lhs.height, rhs.height)
    guard normalizedXDistance <= 0.85, normalizedYDistance <= 0.85 else {
      return 0
    }
    return
      (verticalOverlap * 0.48 + horizontalOverlap * 0.38
      + max(0, 1 - normalizedYDistance) * 0.14)
  }
}

extension CIImage {
  fileprivate func translatedForOCRToOrigin() -> CIImage {
    transformed(
      by: CGAffineTransform(
        translationX: -extent.origin.x,
        y: -extent.origin.y
      )
    )
  }
}

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import ImageIO
import Vision

enum RectangleDetectionSource: String, Sendable {
  case documentSegmentation
  case bookSpreadInference
  case rectangle
  case contrastRectangle
}

struct RectangleCandidate: Sendable {
  let quadrilateral: DocumentQuadrilateral
  let confidence: Float
  let source: RectangleDetectionSource

  init(
    quadrilateral: DocumentQuadrilateral,
    confidence: Float,
    source: RectangleDetectionSource = .rectangle
  ) {
    self.quadrilateral = quadrilateral
    self.confidence = confidence
    self.source = source
  }
}

struct VisionRectangleAnalysis: Sendable {
  let candidate: RectangleCandidate?
  let observationCount: Int
  let suggestedBookGutterRatio: CGFloat?

  init(
    candidate: RectangleCandidate?,
    observationCount: Int,
    suggestedBookGutterRatio: CGFloat? = nil
  ) {
    self.candidate = candidate
    self.observationCount = observationCount
    self.suggestedBookGutterRatio = suggestedBookGutterRatio
  }
}

/// Serial-queue-only hybrid document detector. Apple's document segmentation
/// request is the primary path because it is trained to find paper containing
/// text. A permissive rectangle request covers blank pages and book spreads,
/// while a contrast-enhanced retry covers weak edges and uneven lighting.
final class VisionRectangleDetector {
  private struct ScoredObservation {
    let observation: VNRectangleObservation
    let source: RectangleDetectionSource
    let sourceWeight: CGFloat
  }

  private let documentRequest = VNDetectDocumentSegmentationRequest()
  private let rectangleRequest: VNDetectRectanglesRequest
  private let contrastRectangleRequest: VNDetectRectanglesRequest
  private let bookPageSplitter: BookPageSplitter

  init() {
    rectangleRequest = Self.makeRectangleRequest()
    contrastRectangleRequest = Self.makeRectangleRequest()
    bookPageSplitter = BookPageSplitter(
      context: CIContext(options: [.cacheIntermediates: false])
    )
  }

  func detect(
    pixelBuffer: CVPixelBuffer,
    orientation: CGImagePropertyOrientation = .up,
    mode: ScannerCaptureMode = .singlePage
  ) throws -> RectangleCandidate? {
    try analyze(
      pixelBuffer: pixelBuffer,
      orientation: orientation,
      mode: mode
    ).candidate
  }

  func analyze(
    pixelBuffer: CVPixelBuffer,
    orientation: CGImagePropertyOrientation,
    mode: ScannerCaptureMode = .singlePage
  ) throws -> VisionRectangleAnalysis {
    let image = preparedImage(
      CIImage(cvPixelBuffer: pixelBuffer),
      orientation: orientation
    )
    return try analyzePreparedImage(image, mode: mode)
  }

  func detect(
    image: CIImage,
    orientation: CGImagePropertyOrientation = .up,
    mode: ScannerCaptureMode = .singlePage
  ) throws -> RectangleCandidate? {
    try analyze(
      image: image,
      orientation: orientation,
      mode: mode
    ).candidate
  }

  func analyze(
    image: CIImage,
    orientation: CGImagePropertyOrientation = .up,
    mode: ScannerCaptureMode = .singlePage
  ) throws -> VisionRectangleAnalysis {
    let prepared = preparedImage(image, orientation: orientation)
    return try analyzePreparedImage(prepared, mode: mode)
  }

  private static func makeRectangleRequest() -> VNDetectRectanglesRequest {
    let request = VNDetectRectanglesRequest()
    // WeScan's proven live-scanner structure evaluates multiple candidates
    // and chooses the strongest page. Keep Vision permissive here; geometric
    // scoring and temporal stability reject false automatic captures later.
    request.maximumObservations = 16
    request.minimumConfidence = 0.20
    request.minimumSize = 0.045
    request.minimumAspectRatio = 0.12
    request.maximumAspectRatio = 1.0
    request.quadratureTolerance = 45
    return request
  }

  private func analyzePreparedImage(
    _ image: CIImage,
    mode: ScannerCaptureMode
  ) throws -> VisionRectangleAnalysis {
    let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
    try handler.perform([documentRequest, rectangleRequest])

    let documentObservations = documentRequest.results ?? []
    let rectangleObservations = rectangleRequest.results ?? []
    let bookEstimate =
      mode == .bookTwoPage
      ? bookPageSplitter.estimateGutter(in: image)
      : nil
    let suggestedGutter =
      bookEstimate?.hasTwoPageEvidence == true
      ? bookEstimate?.ratio
      : nil
    let documentCandidate = bestCandidate(
      from: documentObservations.map {
        ScoredObservation(
          observation: $0,
          source: .documentSegmentation,
          sourceWeight: 1.0
        )
      }
    )
    if let documentCandidate {
      return VisionRectangleAnalysis(
        candidate: documentCandidate,
        observationCount: documentObservations.count + rectangleObservations.count,
        suggestedBookGutterRatio: suggestedGutter
      )
    }

    // An open book can legitimately fill the camera frame and have one or more
    // outer corners outside it. In book mode only, a strong central gutter plus
    // texture on both sides lets us recover the full visible spread rather
    // than mistaking one page or a highlighted box for the whole document.
    if let bookEstimate,
       bookEstimate.hasTwoPageEvidence
    {
      let segmentedSpread = bestCandidate(
        from: documentObservations.map {
          ScoredObservation(
            observation: $0,
            source: .bookSpreadInference,
            sourceWeight: 1.0
          )
        },
        allowBorderFilling: true
      )
      let spreadQuadrilateral: DocumentQuadrilateral
      if let segmentedSpread,
         segmentedSpread.quadrilateral.area >= 0.72
      {
        spreadQuadrilateral = segmentedSpread.quadrilateral
      } else {
        // Vision may segment one page or a large internal content panel.
        // Once independent gutter evidence proves a border-filling spread,
        // such a small region is less useful than the full visible frame.
        spreadQuadrilateral = .insetFrame(0.006)
      }
      let spreadConfidence = max(
        Float(bookEstimate.confidence),
        segmentedSpread?.confidence ?? 0
      )
      return VisionRectangleAnalysis(
        candidate: RectangleCandidate(
          quadrilateral: spreadQuadrilateral,
          confidence: spreadConfidence,
          source: .bookSpreadInference
        ),
        observationCount: documentObservations.count + rectangleObservations.count,
        suggestedBookGutterRatio: bookEstimate.ratio
      )
    }

    // Keep the detector source stable across adjacent camera frames. Allowing
    // the segmentation result and a larger generic rectangle to compete by
    // score makes book pages alternate between two different outlines, which
    // prevents the auto-capture timer from ever advancing.
    let rectangleCandidate = bestCandidate(
      from: rectangleObservations.map {
        ScoredObservation(
          observation: $0,
          source: .rectangle,
          sourceWeight: 1.0
        )
      }
    )
    if let rectangleCandidate {
      return VisionRectangleAnalysis(
        candidate: rectangleCandidate,
        observationCount: documentObservations.count + rectangleObservations.count,
        suggestedBookGutterRatio: suggestedGutter
      )
    }

    // Uneven room light, gray paper, and soft shadows can hide the outer
    // border. Retry only when the normal path found nothing so live camera
    // analysis remains responsive on older iPhones and iPads.
    let enhancedImage =
      image
      .applyingFilter(
        "CIColorControls",
        parameters: [
          kCIInputSaturationKey: 0,
          kCIInputContrastKey: 1.45,
          kCIInputBrightnessKey: 0.02,
        ]
      )
      .applyingFilter(
        "CISharpenLuminance",
        parameters: [kCIInputSharpnessKey: 0.35]
      )
    let enhancedHandler = VNImageRequestHandler(
      ciImage: enhancedImage,
      orientation: .up,
      options: [:]
    )
    try enhancedHandler.perform([contrastRectangleRequest])
    let enhancedObservations = contrastRectangleRequest.results ?? []
    let enhancedCandidate = bestCandidate(
      from: enhancedObservations.map {
        ScoredObservation(
          observation: $0,
          source: .contrastRectangle,
          sourceWeight: 0.90
        )
      }
    )
    return VisionRectangleAnalysis(
      candidate: enhancedCandidate,
      observationCount: enhancedObservations.count,
      suggestedBookGutterRatio: suggestedGutter
    )
  }

  private func preparedImage(
    _ image: CIImage,
    orientation: CGImagePropertyOrientation
  ) -> CIImage {
    let oriented = image.oriented(orientation).translatedToOrigin()
    let largestDimension = max(oriented.extent.width, oriented.extent.height)
    guard largestDimension > 1_280 else { return oriented }

    let scale = 1_280 / largestDimension
    let filter = CIFilter.lanczosScaleTransform()
    filter.inputImage = oriented
    filter.scale = Float(scale)
    filter.aspectRatio = 1
    return filter.outputImage?.translatedToOrigin() ?? oriented
  }

  private func bestCandidate(
    from observations: [ScoredObservation],
    allowBorderFilling: Bool = false
  ) -> RectangleCandidate? {
    observations.compactMap {
      scoredObservation -> (candidate: RectangleCandidate, score: CGFloat)? in
      let observation = scoredObservation.observation
      let quadrilateral = DocumentQuadrilateral(
        topLeft: .init(x: observation.topLeft.x, y: observation.topLeft.y),
        topRight: .init(x: observation.topRight.x, y: observation.topRight.y),
        bottomRight: .init(x: observation.bottomRight.x, y: observation.bottomRight.y),
        bottomLeft: .init(x: observation.bottomLeft.x, y: observation.bottomLeft.y)
      )

      let area = quadrilateral.area
      let points = quadrilateral.points
      let horizontalSpan =
        (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
      let verticalSpan =
        (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
      let minimumFrameMargin =
        points.flatMap { point in
          [point.x, 1 - point.x, point.y, 1 - point.y]
        }.min() ?? 0
      guard area >= 0.025,
        area <= 0.995,
        horizontalSpan >= 0.12,
        verticalSpan >= 0.12,
        // Document segmentation can return the entire uniform image as a
        // high-confidence "document". Without visible outer margins there is
        // no reliable perspective boundary, and auto-capturing it is unsafe.
        (allowBorderFilling || !(area > 0.90 && minimumFrameMargin < 0.03))
      else {
        return nil
      }

      // A border-filling rectangle is commonly the display or camera
      // viewport. Keep it as a manual-crop aid, but strongly prefer paper
      // whose corners are visibly separated from the image boundary.
      let borderTouches = points.reduce(into: 0) { count, point in
        if point.x < 0.012 || point.x > 0.988 || point.y < 0.012 || point.y > 0.988 {
          count += 1
        }
      }
      guard allowBorderFilling || borderTouches < 3 else { return nil }
      let borderPenalty: CGFloat
      switch allowBorderFilling ? 0 : borderTouches {
      case 2:
        borderPenalty = 0.72
      default:
        borderPenalty = 1.0
      }

      let confidence = max(observation.confidence, 0.20)
      let score =
        area
        * CGFloat(confidence)
        * scoredObservation.sourceWeight
        * borderPenalty
      return (
        candidate: RectangleCandidate(
          quadrilateral: quadrilateral,
          confidence: confidence,
          source: scoredObservation.source
        ),
        score: score
      )
    }
    .max(by: { $0.score < $1.score })?
    .candidate
  }
}

struct RectangleStabilityTracker {
  private struct Sample {
    let candidate: RectangleCandidate
    let timestamp: TimeInterval
  }

  private var samples: [Sample] = []
  private var displayedQuadrilateral: DocumentQuadrilateral?
  private var lastProgress: CGFloat = 0
  private var missedFrames = 0

  // This is an independent normalized-coordinate implementation of the
  // recent-rectangle consensus used by WeScan's RectangleFeaturesFunnel
  // (MIT). A short history is substantially more tolerant of camera focus
  // pulses, hand jitter, and one-frame Vision misses than a single timer
  // compared only with the previous smoothed rectangle.
  private let maximumSampleCount = 12
  private let maximumSampleAge: TimeInterval = 1.6
  private let minimumDisplayConsensus = 3
  private let requiredAutoCaptureConsensus = 7
  private let displayCornerTolerance: CGFloat = 0.070
  private let autoCaptureCornerTolerance: CGFloat = 0.040
  private let displayAreaTolerance: CGFloat = 0.24
  private let autoCaptureAreaTolerance: CGFloat = 0.16
  private let minimumMeanConfidence: Float = 0.25

  mutating func update(
    candidate: RectangleCandidate?,
    timestamp: TimeInterval
  ) -> LiveRectangleDetection? {
    discardExpiredSamples(at: timestamp)

    guard let candidate else {
      missedFrames += 1
      if missedFrames > 5 {
        reset()
        return nil
      }

      // Keep the agreed outline and gently decay the ring across transient
      // Vision misses. Automatic capture is never allowed on a missing frame.
      guard let displayedQuadrilateral else { return nil }
      let decay = max(0, 1 - CGFloat(missedFrames) * 0.22)
      lastProgress *= decay
      return LiveRectangleDetection(
        quadrilateral: displayedQuadrilateral,
        confidence: 0,
        stabilityProgress: lastProgress,
        isStable: false
      )
    }

    missedFrames = 0
    samples.append(Sample(candidate: candidate, timestamp: timestamp))
    if samples.count > maximumSampleCount {
      samples.removeFirst(samples.count - maximumSampleCount)
    }

    guard let cluster = bestCluster() else {
      displayedQuadrilateral = candidate.quadrilateral
      lastProgress = 0
      return detection(
        quadrilateral: candidate.quadrilateral,
        confidence: candidate.confidence,
        progress: 0,
        isStable: false
      )
    }

    let representative = medianQuadrilateral(
      of: cluster.map(\.candidate.quadrilateral)
    )
    let currentMatchesDisplayCluster = rectanglesMatch(
      candidate.quadrilateral,
      representative,
      cornerTolerance: displayCornerTolerance,
      areaTolerance: displayAreaTolerance
    )

    // Do not let a stale majority automatically capture after the camera has
    // moved to another page. The old outline may remain for a frame or two,
    // but the ring immediately stops until the new page forms a consensus.
    guard currentMatchesDisplayCluster else {
      lastProgress = 0
      return detection(
        quadrilateral: displayedQuadrilateral ?? representative,
        confidence: candidate.confidence,
        progress: 0,
        isStable: false
      )
    }

    displayedQuadrilateral =
      cluster.count >= minimumDisplayConsensus
      ? representative
      : candidate.quadrilateral

    let tightMatches = cluster.filter {
      rectanglesMatch(
        $0.candidate.quadrilateral,
        representative,
        cornerTolerance: autoCaptureCornerTolerance,
        areaTolerance: autoCaptureAreaTolerance
      )
    }
    let currentMatchesAutoCluster = rectanglesMatch(
      candidate.quadrilateral,
      representative,
      cornerTolerance: autoCaptureCornerTolerance,
      areaTolerance: autoCaptureAreaTolerance
    )
    let meanConfidence =
      tightMatches.isEmpty
      ? candidate.confidence
      : tightMatches.reduce(Float.zero) { $0 + $1.candidate.confidence }
        / Float(tightMatches.count)
    let progress = min(
      CGFloat(tightMatches.count) / CGFloat(requiredAutoCaptureConsensus),
      1
    )
    lastProgress = progress
    let isStable =
      currentMatchesAutoCluster
      && tightMatches.count >= requiredAutoCaptureConsensus
      && meanConfidence >= minimumMeanConfidence

    return detection(
      quadrilateral: displayedQuadrilateral ?? representative,
      confidence: meanConfidence,
      progress: progress,
      isStable: isStable
    )
  }

  mutating func reset() {
    samples.removeAll(keepingCapacity: true)
    displayedQuadrilateral = nil
    lastProgress = 0
    missedFrames = 0
  }

  private mutating func discardExpiredSamples(at timestamp: TimeInterval) {
    samples.removeAll { timestamp - $0.timestamp > maximumSampleAge }
  }

  private func bestCluster() -> [Sample]? {
    guard !samples.isEmpty else { return nil }

    let scored = samples.enumerated().map { index, anchor in
      let members = samples.filter {
        rectanglesMatch(
          anchor.candidate.quadrilateral,
          $0.candidate.quadrilateral,
          cornerTolerance: displayCornerTolerance,
          areaTolerance: displayAreaTolerance
        )
      }
      let distanceToDisplayed = displayedQuadrilateral.map {
        anchor.candidate.quadrilateral.maximumCornerDistance(to: $0)
      } ?? .greatestFiniteMagnitude
      return (
        index: index,
        members: members,
        distanceToDisplayed: distanceToDisplayed
      )
    }

    // Highest consensus wins. Ties prefer the currently displayed page to
    // prevent outline flicker, then the newest sample.
    return scored.max { lhs, rhs in
      if lhs.members.count != rhs.members.count {
        return lhs.members.count < rhs.members.count
      }
      if lhs.distanceToDisplayed != rhs.distanceToDisplayed {
        return lhs.distanceToDisplayed > rhs.distanceToDisplayed
      }
      return lhs.index < rhs.index
    }?.members
  }

  private func rectanglesMatch(
    _ lhs: DocumentQuadrilateral,
    _ rhs: DocumentQuadrilateral,
    cornerTolerance: CGFloat,
    areaTolerance: CGFloat
  ) -> Bool {
    guard lhs.maximumCornerDistance(to: rhs) <= cornerTolerance else {
      return false
    }
    let areaDenominator = max(min(lhs.area, rhs.area), 0.001)
    return abs(lhs.area - rhs.area) / areaDenominator <= areaTolerance
  }

  private func medianQuadrilateral(
    of quadrilaterals: [DocumentQuadrilateral]
  ) -> DocumentQuadrilateral {
    guard !quadrilaterals.isEmpty else {
      return .insetFrame()
    }

    func median(_ values: [CGFloat]) -> CGFloat {
      let sorted = values.sorted()
      let middle = sorted.count / 2
      if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
      }
      return sorted[middle]
    }

    func point(_ keyPath: KeyPath<DocumentQuadrilateral, NormalizedPoint>) -> NormalizedPoint {
      NormalizedPoint(
        x: median(quadrilaterals.map { $0[keyPath: keyPath].x }),
        y: median(quadrilaterals.map { $0[keyPath: keyPath].y })
      )
    }

    return DocumentQuadrilateral(
      topLeft: point(\.topLeft),
      topRight: point(\.topRight),
      bottomRight: point(\.bottomRight),
      bottomLeft: point(\.bottomLeft)
    )
  }

  private func detection(
    quadrilateral: DocumentQuadrilateral,
    confidence: Float,
    progress: CGFloat,
    isStable: Bool
  ) -> LiveRectangleDetection {
    LiveRectangleDetection(
      quadrilateral: quadrilateral,
      confidence: confidence,
      stabilityProgress: progress,
      isStable: isStable
    )
  }
}

import CoreGraphics
import Foundation

public enum BookPageGutterSide: String, CaseIterable, Sendable {
  case left
  case right
}

public enum BookPageDewarpRejectionReason: String, Equatable, Sendable {
  case imageTooSmall
  case insufficientLineEvidence
  case correctionNotNeeded
  case inconsistentCurve
  case renderingFailed
}

public struct BookPageDewarpDiagnostics: Equatable, Sendable {
  public let confidence: Double
  public let scaleAmplitude: Double
  public let normalizedOffsetAmplitude: Double
  public let maximumVerticalDisplacementFraction: Double
  public let reliableStripCount: Int
  public let meanCorrelationGain: Double
  public let controlColumnCount: Int

  public init(
    confidence: Double,
    scaleAmplitude: Double,
    normalizedOffsetAmplitude: Double,
    maximumVerticalDisplacementFraction: Double,
    reliableStripCount: Int,
    meanCorrelationGain: Double,
    controlColumnCount: Int
  ) {
    self.confidence = confidence
    self.scaleAmplitude = scaleAmplitude
    self.normalizedOffsetAmplitude = normalizedOffsetAmplitude
    self.maximumVerticalDisplacementFraction = maximumVerticalDisplacementFraction
    self.reliableStripCount = reliableStripCount
    self.meanCorrelationGain = meanCorrelationGain
    self.controlColumnCount = controlColumnCount
  }
}

/// Always returns an image. When geometric evidence is weak, `image` is the
/// exact input `CGImage` and `wasApplied` is false.
public struct BookPageDewarpResult {
  public let image: CGImage
  public let wasApplied: Bool
  public let rejectionReason: BookPageDewarpRejectionReason?
  public let diagnostics: BookPageDewarpDiagnostics
}

/// A conservative, deterministic book-page dewarper.
///
/// This is intentionally narrower than a learned general document dewarper.
/// It handles the common cylindrical book curve where horizontal baselines
/// converge toward the page's vertical center near the gutter. Row-wise ink
/// profiles from vertical strips estimate a bounded scale/offset curve. That
/// curve becomes a sparse backward-mapping mesh, sampled with linear
/// interpolation. Pages without enough repeated horizontal structure, pages
/// that are already flat, and curves that do not fit this model are returned
/// unchanged.
public final class BookPageDewarper: @unchecked Sendable {
  private let maximumAnalysisDimension: Int
  private let minimumConfidence: Double
  private let analysisStripCount = 17
  private let meshColumnCount = 17

  public init(
    maximumAnalysisDimension: Int = 640,
    minimumConfidence: Double = 0.56
  ) {
    self.maximumAnalysisDimension = max(maximumAnalysisDimension, 160)
    self.minimumConfidence = min(max(minimumConfidence, 0.35), 0.9)
  }

  public func dewarp(
    _ image: CGImage,
    gutterSide: BookPageGutterSide
  ) -> BookPageDewarpResult {
    guard image.width >= 120, image.height >= 160 else {
      return unchanged(image, reason: .imageTooSmall)
    }
    guard let analysisImage = makeAnalysisImage(image) else {
      return unchanged(image, reason: .renderingFailed)
    }

    switch estimateCurve(in: analysisImage, gutterSide: gutterSide) {
    case .failure(let reason):
      return unchanged(image, reason: reason)
    case .success(let curve):
      guard
        let output = render(
          image,
          gutterSide: gutterSide,
          scaleAmplitude: curve.scaleAmplitude,
          normalizedOffsetAmplitude: curve.normalizedOffsetAmplitude
        )
      else {
        return unchanged(
          image,
          reason: .renderingFailed,
          diagnostics: curve.diagnostics
        )
      }
      return BookPageDewarpResult(
        image: output,
        wasApplied: true,
        rejectionReason: nil,
        diagnostics: curve.diagnostics
      )
    }
  }

  private func unchanged(
    _ image: CGImage,
    reason: BookPageDewarpRejectionReason,
    diagnostics: BookPageDewarpDiagnostics? = nil
  ) -> BookPageDewarpResult {
    BookPageDewarpResult(
      image: image,
      wasApplied: false,
      rejectionReason: reason,
      diagnostics: diagnostics
        ?? BookPageDewarpDiagnostics(
          confidence: 0,
          scaleAmplitude: 0,
          normalizedOffsetAmplitude: 0,
          maximumVerticalDisplacementFraction: 0,
          reliableStripCount: 0,
          meanCorrelationGain: 0,
          controlColumnCount: meshColumnCount
        )
    )
  }

  private struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]
  }

  private struct StripEstimate {
    let gutterDistance: Double
    let curveWeight: Double
    let scale: Double
    let offset: Double
    let score: Double
    let gain: Double
  }

  private struct CurveEstimate {
    let scaleAmplitude: Double
    let normalizedOffsetAmplitude: Double
    let diagnostics: BookPageDewarpDiagnostics
  }

  private enum CurveEstimation {
    case success(CurveEstimate)
    case failure(BookPageDewarpRejectionReason)
  }

  private func makeAnalysisImage(_ image: CGImage) -> GrayImage? {
    let longest = max(image.width, image.height)
    let scale = min(1, Double(maximumAnalysisDimension) / Double(longest))
    let width = max(Int((Double(image.width) * scale).rounded()), 1)
    let height = max(Int((Double(image.height) * scale).rounded()), 1)
    var pixels = [UInt8](repeating: 255, count: width * height)
    guard
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else {
      return nil
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return GrayImage(width: width, height: height, pixels: pixels)
  }

  private func estimateCurve(
    in image: GrayImage,
    gutterSide: BookPageGutterSide
  ) -> CurveEstimation {
    let histogram = image.pixels.reduce(into: [Int](repeating: 0, count: 256)) {
      $0[Int($1)] += 1
    }
    let paperLevel = percentile(0.82, histogram: histogram, count: image.pixels.count)
    let darkCutoff = max(paperLevel - 28, 24)
    let darkCount = image.pixels.reduce(0) { $0 + ($1 < darkCutoff ? 1 : 0) }
    let inkCoverage = Double(darkCount) / Double(max(image.pixels.count, 1))
    guard inkCoverage >= 0.004, inkCoverage <= 0.42 else {
      return .failure(.insufficientLineEvidence)
    }

    let stripCenters = (0..<analysisStripCount).map { index in
      0.055 + 0.89 * Double(index) / Double(analysisStripCount - 1)
    }
    let halfWidth = max(image.width / (analysisStripCount * 4), 2)
    let profiles = stripCenters.map {
      rowProfile(
        image,
        centerX: Int((Double(image.width - 1) * $0).rounded()),
        halfWidth: halfWidth,
        paperLevel: paperLevel
      )
    }
    let gutterDistances = stripCenters.map {
      gutterSide == .left ? $0 : 1 - $0
    }
    let outerIndices = gutterDistances.indices.filter {
      gutterDistances[$0] >= 0.66 && gutterDistances[$0] <= 0.94
    }
    guard
      outerIndices.count >= 3,
      let reference = normalizedAverage(
        outerIndices.map { profiles[$0] }
      )
    else {
      return .failure(.insufficientLineEvidence)
    }

    var estimates: [StripEstimate] = []
    let offsetLimit = max(Int((Double(image.height) * 0.028).rounded()), 2)
    let offsetStep = max(image.height / 260, 1)
    for index in stripCenters.indices {
      let distance = gutterDistances[index]
      let weight = curveWeight(distance)
      guard weight >= 0.10, profileEnergy(profiles[index]) >= 0.008 else { continue }
      let identity = correlation(
        reference: reference,
        sample: profiles[index],
        scale: 1,
        offset: 0
      )
      var bestScale = 1.0
      var bestOffset = 0.0
      var bestScore = identity

      for scaleStep in -20...20 {
        let scale = 1 + Double(scaleStep) * 0.005
        var offset = -offsetLimit
        while offset <= offsetLimit {
          let score = correlation(
            reference: reference,
            sample: profiles[index],
            scale: scale,
            offset: Double(offset)
          )
          if score > bestScore {
            bestScore = score
            bestScale = scale
            bestOffset = Double(offset)
          }
          offset += offsetStep
        }
      }
      let gain = bestScore - identity
      if bestScore >= 0.22, gain >= 0.008 {
        estimates.append(
          StripEstimate(
            gutterDistance: distance,
            curveWeight: weight,
            scale: bestScale,
            offset: bestOffset,
            score: bestScore,
            gain: gain
          )
        )
      }
    }

    guard estimates.count >= 5 else {
      return .failure(.insufficientLineEvidence)
    }

    let fitted = fitCurve(estimates, imageHeight: image.height)
    let scaleAmplitude = fitted.scaleAmplitude
    let offsetAmplitude = fitted.normalizedOffsetAmplitude
    let signal = 0.5 * abs(scaleAmplitude) + abs(offsetAmplitude)
    guard signal >= 0.009 else {
      return .failure(.correctionNotNeeded)
    }
    guard
      abs(scaleAmplitude) <= 0.095,
      abs(offsetAmplitude) <= 0.04,
      fitted.scaleResidual <= 0.025,
      fitted.offsetResidual <= 0.022,
      fitted.signConsistency >= 0.64
    else {
      return .failure(.inconsistentCurve)
    }

    let evidenceFraction = min(Double(estimates.count) / 9, 1)
    let scoreComponent = clamp01((fitted.meanScore - 0.22) / 0.48)
    let gainComponent = clamp01(fitted.meanGain / 0.10)
    let residualComponent = clamp01(
      1 - fitted.scaleResidual / 0.025 - fitted.offsetResidual / 0.030
    )
    let confidence = clamp01(
      0.28 * evidenceFraction
        + 0.30 * scoreComponent
        + 0.22 * gainComponent
        + 0.20 * residualComponent
    )
    guard confidence >= minimumConfidence else {
      return .failure(.inconsistentCurve)
    }

    let diagnostics = BookPageDewarpDiagnostics(
      confidence: confidence,
      scaleAmplitude: scaleAmplitude,
      normalizedOffsetAmplitude: offsetAmplitude,
      maximumVerticalDisplacementFraction: signal,
      reliableStripCount: estimates.count,
      meanCorrelationGain: fitted.meanGain,
      controlColumnCount: meshColumnCount
    )
    return .success(
      CurveEstimate(
        scaleAmplitude: scaleAmplitude,
        normalizedOffsetAmplitude: offsetAmplitude,
        diagnostics: diagnostics
      )
    )
  }

  private func percentile(
    _ fraction: Double,
    histogram: [Int],
    count: Int
  ) -> Int {
    let target = Int(Double(count) * fraction)
    var cumulative = 0
    for (value, occurrences) in histogram.enumerated() {
      cumulative += occurrences
      if cumulative >= target { return value }
    }
    return 255
  }

  private func rowProfile(
    _ image: GrayImage,
    centerX: Int,
    halfWidth: Int,
    paperLevel: Int
  ) -> [Double] {
    let lowerX = max(centerX - halfWidth, 0)
    let upperX = min(centerX + halfWidth, image.width - 1)
    let sampleWidth = max(upperX - lowerX + 1, 1)
    var darkness = [Double](repeating: 0, count: image.height)
    for y in 0..<image.height {
      var total = 0.0
      let row = y * image.width
      for x in lowerX...upperX {
        total += Double(max(paperLevel - Int(image.pixels[row + x]) - 8, 0))
      }
      darkness[y] = total / Double(sampleWidth)
    }

    let radius = max(image.height / 80, 3)
    var integral = [Double](repeating: 0, count: image.height + 1)
    for index in darkness.indices {
      integral[index + 1] = integral[index] + darkness[index]
    }
    var highPass = [Double](repeating: 0, count: image.height)
    for y in darkness.indices {
      let lower = max(y - radius, 0)
      let upper = min(y + radius + 1, image.height)
      let localMean = (integral[upper] - integral[lower]) / Double(upper - lower)
      highPass[y] = darkness[y] - localMean
    }
    return normalize(highPass) ?? highPass
  }

  private func normalizedAverage(_ profiles: [[Double]]) -> [Double]? {
    guard let first = profiles.first, !first.isEmpty else { return nil }
    var average = [Double](repeating: 0, count: first.count)
    for profile in profiles where profile.count == average.count {
      for index in average.indices {
        average[index] += profile[index]
      }
    }
    let divisor = Double(profiles.count)
    for index in average.indices {
      average[index] /= divisor
    }
    return normalize(average)
  }

  private func normalize(_ values: [Double]) -> [Double]? {
    guard !values.isEmpty else { return nil }
    let mean = values.reduce(0, +) / Double(values.count)
    let centered = values.map { $0 - mean }
    let norm = sqrt(centered.reduce(0) { $0 + $1 * $1 })
    guard norm > 1e-7 else { return nil }
    return centered.map { $0 / norm }
  }

  private func profileEnergy(_ profile: [Double]) -> Double {
    guard !profile.isEmpty else { return 0 }
    return sqrt(profile.reduce(0) { $0 + $1 * $1 } / Double(profile.count))
  }

  private func correlation(
    reference: [Double],
    sample: [Double],
    scale: Double,
    offset: Double
  ) -> Double {
    guard reference.count == sample.count, reference.count >= 40 else { return -1 }
    let height = reference.count
    let margin = max(height / 18, 4)
    let center = Double(height - 1) * 0.5
    var sumR = 0.0
    var sumS = 0.0
    var sumRR = 0.0
    var sumSS = 0.0
    var sumRS = 0.0
    var count = 0.0
    for y in margin..<(height - margin) {
      let sourceY = center + (Double(y) - center) * scale + offset
      guard sourceY >= 0, sourceY < Double(height - 1) else { continue }
      let lower = Int(sourceY)
      let fraction = sourceY - Double(lower)
      let sampled = sample[lower] * (1 - fraction) + sample[lower + 1] * fraction
      let expected = reference[y]
      sumR += expected
      sumS += sampled
      sumRR += expected * expected
      sumSS += sampled * sampled
      sumRS += expected * sampled
      count += 1
    }
    guard count >= Double(height) * 0.72 else { return -1 }
    let numerator = sumRS - sumR * sumS / count
    let varianceR = max(sumRR - sumR * sumR / count, 0)
    let varianceS = max(sumSS - sumS * sumS / count, 0)
    let denominator = sqrt(varianceR * varianceS)
    return denominator > 1e-10 ? numerator / denominator : -1
  }

  private func fitCurve(
    _ estimates: [StripEstimate],
    imageHeight: Int
  ) -> (
    scaleAmplitude: Double,
    normalizedOffsetAmplitude: Double,
    scaleResidual: Double,
    offsetResidual: Double,
    signConsistency: Double,
    meanScore: Double,
    meanGain: Double
  ) {
    var denominator = 0.0
    var scaleNumerator = 0.0
    var offsetNumerator = 0.0
    var totalEvidence = 0.0
    for estimate in estimates {
      let evidence = max(estimate.score - 0.12, 0.01)
      denominator += evidence * estimate.curveWeight * estimate.curveWeight
      scaleNumerator +=
        evidence * estimate.curveWeight * (estimate.scale - 1)
      offsetNumerator +=
        evidence * estimate.curveWeight * estimate.offset / Double(imageHeight)
      totalEvidence += evidence
    }
    let scaleAmplitude = denominator > 0 ? scaleNumerator / denominator : 0
    let offsetAmplitude = denominator > 0 ? offsetNumerator / denominator : 0

    var scaleError = 0.0
    var offsetError = 0.0
    var matchingSignWeight = 0.0
    var signWeight = 0.0
    for estimate in estimates {
      let evidence = max(estimate.score - 0.12, 0.01)
      let expectedScale = 1 + scaleAmplitude * estimate.curveWeight
      let expectedOffset = offsetAmplitude * estimate.curveWeight
      scaleError += evidence * pow(estimate.scale - expectedScale, 2)
      offsetError +=
        evidence * pow(estimate.offset / Double(imageHeight) - expectedOffset, 2)
      if abs(estimate.scale - 1) >= 0.004, abs(scaleAmplitude) >= 0.004 {
        signWeight += evidence
        if (estimate.scale - 1) * scaleAmplitude > 0 {
          matchingSignWeight += evidence
        }
      }
    }

    return (
      scaleAmplitude,
      offsetAmplitude,
      sqrt(scaleError / max(totalEvidence, 1e-8)),
      sqrt(offsetError / max(totalEvidence, 1e-8)),
      signWeight > 0 ? matchingSignWeight / signWeight : 1,
      estimates.reduce(0) { $0 + $1.score } / Double(estimates.count),
      estimates.reduce(0) { $0 + $1.gain } / Double(estimates.count)
    )
  }

  private struct MeshColumn {
    let x: Double
    let scale: Double
    let normalizedOffset: Double
  }

  private func makeMesh(
    gutterSide: BookPageGutterSide,
    scaleAmplitude: Double,
    normalizedOffsetAmplitude: Double
  ) -> [MeshColumn] {
    (0..<meshColumnCount).map { index in
      let x = Double(index) / Double(meshColumnCount - 1)
      let gutterDistance = gutterSide == .left ? x : 1 - x
      let weight = curveWeight(gutterDistance)
      return MeshColumn(
        x: x,
        scale: 1 + scaleAmplitude * weight,
        normalizedOffset: normalizedOffsetAmplitude * weight
      )
    }
  }

  private func render(
    _ image: CGImage,
    gutterSide: BookPageGutterSide,
    scaleAmplitude: Double,
    normalizedOffsetAmplitude: Double
  ) -> CGImage? {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    var source = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard
      let sourceContext = CGContext(
        data: &source,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
      )
    else {
      return nil
    }
    sourceContext.interpolationQuality = .high
    sourceContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let mesh = makeMesh(
      gutterSide: gutterSide,
      scaleAmplitude: scaleAmplitude,
      normalizedOffsetAmplitude: normalizedOffsetAmplitude
    )
    var scales = [Double](repeating: 1, count: width)
    var offsets = [Double](repeating: 0, count: width)
    for x in 0..<width {
      let normalizedX = width > 1 ? Double(x) / Double(width - 1) : 0
      let meshPosition = normalizedX * Double(mesh.count - 1)
      let lowerIndex = min(Int(meshPosition), mesh.count - 2)
      let fraction = meshPosition - Double(lowerIndex)
      let lower = mesh[lowerIndex]
      let upper = mesh[lowerIndex + 1]
      scales[x] = lower.scale * (1 - fraction) + upper.scale * fraction
      offsets[x] =
        (lower.normalizedOffset * (1 - fraction) + upper.normalizedOffset * fraction)
        * Double(height)
    }

    let centerY = Double(height - 1) * 0.5
    var destination = [UInt8](repeating: 0, count: source.count)
    for y in 0..<height {
      for x in 0..<width {
        let mappedY = min(
          max(centerY + (Double(y) - centerY) * scales[x] + offsets[x], 0),
          Double(height - 1)
        )
        let lowerY = Int(mappedY)
        let upperY = min(lowerY + 1, height - 1)
        let fraction = mappedY - Double(lowerY)
        let destinationOffset = y * bytesPerRow + x * 4
        let lowerOffset = lowerY * bytesPerRow + x * 4
        let upperOffset = upperY * bytesPerRow + x * 4
        for channel in 0..<4 {
          let value =
            Double(source[lowerOffset + channel]) * (1 - fraction)
            + Double(source[upperOffset + channel]) * fraction
          destination[destinationOffset + channel] =
            UInt8(min(max(Int(value.rounded()), 0), 255))
        }
      }
    }

    guard let provider = CGDataProvider(data: Data(destination) as CFData) else {
      return nil
    }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: image.renderingIntent
    )
  }

  /// Cubic smoothstep falloff: full correction at the gutter, zero before the
  /// outer quarter so already-flat content remains untouched.
  private func curveWeight(_ gutterDistance: Double) -> Double {
    let support = 0.78
    guard gutterDistance < support else { return 0 }
    let t = min(max(gutterDistance / support, 0), 1)
    let smoothstep = t * t * (3 - 2 * t)
    return 1 - smoothstep
  }

  private func clamp01(_ value: Double) -> Double {
    min(max(value, 0), 1)
  }
}

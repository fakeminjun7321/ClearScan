import CoreGraphics
import Foundation
import ImageIO

/// The scanner's output mode. Book mode detects one outer spread and returns
/// separate left and right page images.
public enum ScannerCaptureMode: String, CaseIterable, Sendable {
    case singlePage
    case bookTwoPage
}

public enum ScannerAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public enum ScannerPhase: Equatable, Sendable {
    case idle
    case configuring
    case searching
    case stabilizing(progress: CGFloat)
    case ready
    case countdown(remainingSeconds: Int)
    case capturing
    case processing
    case completed
    case failed(message: String)
}

public enum ScannerCaptureTimer: Int, CaseIterable, Hashable, Sendable {
    case off = 0
    case threeSeconds = 3
    case fiveSeconds = 5

    public var title: String {
        switch self {
        case .off: "끔"
        case .threeSeconds: "3초"
        case .fiveSeconds: "5초"
        }
    }

    var countdownValues: [Int] {
        guard rawValue > 0 else { return [] }
        return Array(stride(from: rawValue, through: 1, by: -1))
    }
}

public enum ScannerCaptureQuality: String, CaseIterable, Hashable, Sendable {
    case silentVideoFrame
    case highQualityPhoto

    public var title: String {
        switch self {
        case .silentVideoFrame: "완전 무음"
        case .highQualityPhoto: "고화질 사진"
        }
    }

    public var shortTitle: String {
        switch self {
        case .silentVideoFrame: "무음"
        case .highQualityPhoto: "고화질"
        }
    }

    /// Silent mode uses the current video-stream pixel dimensions and dynamic
    /// range. High-quality mode uses the camera's largest supported photo
    /// dimensions, but iOS may play the system shutter sound.
    public var limitationDescription: String {
        switch self {
        case .silentVideoFrame:
            "동영상 스트림의 최신 프레임을 사용합니다. 완전히 무음이지만 해상도와 명암 범위는 고화질 사진보다 낮고 기기별로 다릅니다."
        case .highQualityPhoto:
            "카메라가 지원하는 최대 사진 크기로 촬영합니다. 더 선명하지만 iOS 시스템 셔터음이 날 수 있어 무음을 보장하지 않습니다."
        }
    }
}

public enum ScannerCameraLens: String, CaseIterable, Hashable, Sendable {
    case ultraWide
    case standard

    public var title: String {
        switch self {
        case .ultraWide: "0.5×"
        case .standard: "1×"
        }
    }
}

public struct ScannerCameraCapabilities: Equatable, Sendable {
    public let availableLenses: [ScannerCameraLens]

    public init(availableLenses: [ScannerCameraLens]) {
        let available = Set(availableLenses)
        self.availableLenses = ScannerCameraLens.allCases.filter {
            $0 == .standard || available.contains($0)
        }
    }

    public func resolvedLens(
        requested: ScannerCameraLens
    ) -> ScannerCameraLens {
        availableLenses.contains(requested) ? requested : .standard
    }
}

/// The orientation that turns a sensor-native camera buffer into the current
/// interface orientation. `CVPixelBuffer` does not carry this metadata, so the
/// value must be supplied explicitly to Vision for every analyzed frame.
public enum ScannerFrameOrientation: String, CaseIterable, Sendable {
    case up
    case right
    case down
    case left

    public init(videoRotationAngle: CGFloat) {
        let normalized = (
            videoRotationAngle.truncatingRemainder(dividingBy: 360) + 360
        ).truncatingRemainder(dividingBy: 360)
        switch Int((normalized / 90).rounded()) % 4 {
        case 1:
            self = .right
        case 2:
            self = .down
        case 3:
            self = .left
        default:
            self = .up
        }
    }

    var imagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up:
            return .up
        case .right:
            return .right
        case .down:
            return .down
        case .left:
            return .left
        }
    }

    /// Converts a Vision point in the oriented image back to the sensor-native
    /// Vision coordinate space. AVCaptureVideoPreviewLayer then handles its own
    /// aspect-fill crop and display rotation.
    func rawVisionPoint(fromOriented point: NormalizedPoint) -> NormalizedPoint {
        switch self {
        case .up:
            return point.clamped()
        case .right:
            return NormalizedPoint(x: 1 - point.y, y: point.x).clamped()
        case .down:
            return NormalizedPoint(x: 1 - point.x, y: 1 - point.y).clamped()
        case .left:
            return NormalizedPoint(x: point.y, y: 1 - point.x).clamped()
        }
    }
}

/// Live, user-observable health information for camera frame analysis. The
/// camera UI can bind to `statusText` to distinguish "no paper found" from
/// "Vision is not receiving frames" or "Vision is throwing an error".
public struct ScannerAnalysisDiagnostics: Equatable, Sendable {
    public let receivedFrameCount: Int
    public let analyzedFrameCount: Int
    public let candidateFrameCount: Int
    public let lastObservationCount: Int
    public let visionErrorCount: Int
    public let frameWidth: Int
    public let frameHeight: Int
    public let orientation: ScannerFrameOrientation
    public let lastErrorDescription: String?

    public init(
        receivedFrameCount: Int = 0,
        analyzedFrameCount: Int = 0,
        candidateFrameCount: Int = 0,
        lastObservationCount: Int = 0,
        visionErrorCount: Int = 0,
        frameWidth: Int = 0,
        frameHeight: Int = 0,
        orientation: ScannerFrameOrientation = .right,
        lastErrorDescription: String? = nil
    ) {
        self.receivedFrameCount = receivedFrameCount
        self.analyzedFrameCount = analyzedFrameCount
        self.candidateFrameCount = candidateFrameCount
        self.lastObservationCount = lastObservationCount
        self.visionErrorCount = visionErrorCount
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.orientation = orientation
        self.lastErrorDescription = lastErrorDescription
    }

    public var statusText: String {
        if let lastErrorDescription {
            return "AI 분석 오류 \(visionErrorCount)회 · \(lastErrorDescription)"
        }
        guard receivedFrameCount > 0 else {
            return "카메라 프레임 대기 중"
        }
        guard analyzedFrameCount > 0 else {
            return "프레임 \(receivedFrameCount)개 수신 · 분석 대기"
        }
        return "AI \(analyzedFrameCount)프레임 · 사각형 \(lastObservationCount)개"
    }
}

/// A normalized coordinate in Vision's image coordinate space: origin at the
/// lower-left, x increasing right, and y increasing up.
public struct NormalizedPoint: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public func clamped() -> NormalizedPoint {
        NormalizedPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    public static func interpolate(
        from start: NormalizedPoint,
        to end: NormalizedPoint,
        amount: CGFloat
    ) -> NormalizedPoint {
        let t = min(max(amount, 0), 1)
        return NormalizedPoint(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t
        )
    }
}

public struct DocumentQuadrilateral: Equatable, Sendable {
    public var topLeft: NormalizedPoint
    public var topRight: NormalizedPoint
    public var bottomRight: NormalizedPoint
    public var bottomLeft: NormalizedPoint

    public init(
        topLeft: NormalizedPoint,
        topRight: NormalizedPoint,
        bottomRight: NormalizedPoint,
        bottomLeft: NormalizedPoint
    ) {
        self.topLeft = topLeft.clamped()
        self.topRight = topRight.clamped()
        self.bottomRight = bottomRight.clamped()
        self.bottomLeft = bottomLeft.clamped()
    }

    /// A conservative full-frame fallback used only for a manual shutter press
    /// when Vision cannot find page edges. Automatic capture still requires a
    /// real rectangle detection.
    public static func insetFrame(_ inset: CGFloat = 0.04) -> DocumentQuadrilateral {
        let value = min(max(inset, 0), 0.45)
        return DocumentQuadrilateral(
            topLeft: NormalizedPoint(x: value, y: 1 - value),
            topRight: NormalizedPoint(x: 1 - value, y: 1 - value),
            bottomRight: NormalizedPoint(x: 1 - value, y: value),
            bottomLeft: NormalizedPoint(x: value, y: value)
        )
    }

    public var points: [NormalizedPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    public var area: CGFloat {
        let vertices = points
        var signedArea: CGFloat = 0
        for index in vertices.indices {
            let next = vertices[(index + 1) % vertices.count]
            signedArea += vertices[index].x * next.y - next.x * vertices[index].y
        }
        return abs(signedArea) * 0.5
    }

    public func interpolated(toward other: DocumentQuadrilateral, amount: CGFloat) -> DocumentQuadrilateral {
        DocumentQuadrilateral(
            topLeft: .interpolate(from: topLeft, to: other.topLeft, amount: amount),
            topRight: .interpolate(from: topRight, to: other.topRight, amount: amount),
            bottomRight: .interpolate(from: bottomRight, to: other.bottomRight, amount: amount),
            bottomLeft: .interpolate(from: bottomLeft, to: other.bottomLeft, amount: amount)
        )
    }

    public func maximumCornerDistance(to other: DocumentQuadrilateral) -> CGFloat {
        zip(points, other.points).map { lhs, rhs in
            hypot(lhs.x - rhs.x, lhs.y - rhs.y)
        }.max() ?? 0
    }
}

public struct LiveRectangleDetection: Equatable, Sendable {
    public let quadrilateral: DocumentQuadrilateral
    public let confidence: Float
    public let stabilityProgress: CGFloat
    public let isStable: Bool
    /// The outline is useful for framing, but one or more document edges are
    /// outside the camera frame so automatic capture must stay disabled.
    public let requiresRepositioning: Bool

    public init(
        quadrilateral: DocumentQuadrilateral,
        confidence: Float,
        stabilityProgress: CGFloat,
        isStable: Bool,
        requiresRepositioning: Bool = false
    ) {
        self.quadrilateral = quadrilateral
        self.confidence = confidence
        self.stabilityProgress = min(max(stabilityProgress, 0), 1)
        self.isStable = isStable
        self.requiresRepositioning = requiresRepositioning
    }
}

public enum CapturedPageSide: String, Sendable {
    case single
    case left
    case right
}

public struct CapturedPage: @unchecked Sendable {
    public let id: UUID
    public let side: CapturedPageSide
    public let image: CGImage

    public init(id: UUID = UUID(), side: CapturedPageSide, image: CGImage) {
        self.id = id
        self.side = side
        self.image = image
    }
}

public struct ScannerCaptureResult: @unchecked Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let mode: ScannerCaptureMode
    public let pages: [CapturedPage]
    public let documentQuadrilateral: DocumentQuadrilateral
    public let gutterRatio: CGFloat?
    public let usedAutomaticGutter: Bool

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        mode: ScannerCaptureMode,
        pages: [CapturedPage],
        documentQuadrilateral: DocumentQuadrilateral,
        gutterRatio: CGFloat? = nil,
        usedAutomaticGutter: Bool = false
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.mode = mode
        self.pages = pages
        self.documentQuadrilateral = documentQuadrilateral
        self.gutterRatio = gutterRatio
        self.usedAutomaticGutter = usedAutomaticGutter
    }
}

public enum ScannerCoreError: LocalizedError, Equatable, Sendable {
    case cameraUnavailable
    case cameraPermissionDenied
    case sessionConfigurationFailed
    case captureFailed(String)
    case imageDecodingFailed
    case documentNotFound
    case perspectiveCorrectionFailed
    case renderingFailed
    case bookSpreadUnavailable

    public var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "사용할 수 있는 후면 카메라가 없습니다."
        case .cameraPermissionDenied:
            return "카메라 권한이 필요합니다."
        case .sessionConfigurationFailed:
            return "카메라를 시작하지 못했습니다."
        case let .captureFailed(message):
            return "사진 촬영에 실패했습니다: \(message)"
        case .imageDecodingFailed:
            return "촬영한 이미지를 읽지 못했습니다."
        case .documentNotFound:
            return "사진에서 문서 사각형을 찾지 못했습니다."
        case .perspectiveCorrectionFailed:
            return "문서 원근 보정에 실패했습니다."
        case .renderingFailed:
            return "보정 결과 이미지를 만들지 못했습니다."
        case .bookSpreadUnavailable:
            return "다시 나눌 책 펼침면이 없습니다."
        }
    }
}

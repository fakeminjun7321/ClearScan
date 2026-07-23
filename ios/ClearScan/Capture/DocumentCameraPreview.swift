import AVFoundation
import SwiftUI
import UIKit

/// SwiftUI bridge for the scanner's AVCaptureSession and live rectangle state.
/// The overlay is converted through AVCaptureVideoPreviewLayer, so aspect-fill
/// cropping and device rotation remain aligned with the camera preview.
public struct DocumentCameraPreview: UIViewRepresentable {
    @ObservedObject private var scanner: DocumentScannerModel

    public init(scanner: DocumentScannerModel) {
        self.scanner = scanner
    }

    public func makeUIView(context: Context) -> ScannerPreviewSurface {
        let view = ScannerPreviewSurface()
        view.previewLayer.session = scanner.session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    public func updateUIView(_ uiView: ScannerPreviewSurface, context: Context) {
        if uiView.previewLayer.session !== scanner.session {
            uiView.previewLayer.session = scanner.session
        }
        let gutterRatio: CGFloat? = scanner.captureMode == .bookTwoPage
            ? scanner.manualGutterRatio ?? scanner.liveBookGutterRatio ?? 0.5
            : nil
        uiView.updateOverlay(
            detection: scanner.liveDetection,
            gutterRatio: gutterRatio
        )
    }

    public static func dismantleUIView(_ uiView: ScannerPreviewSurface, coordinator: Void) {
        uiView.previewLayer.session = nil
    }
}

public final class ScannerPreviewSurface: UIView {
    private let quadrilateralLayer = CAShapeLayer()
    private let gutterLayer = CAShapeLayer()
    private var detection: LiveRectangleDetection?
    private var gutterRatio: CGFloat?

    public override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("ScannerPreviewSurface must use AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "문서 카메라 미리보기"

        quadrilateralLayer.fillColor = UIColor.clear.cgColor
        quadrilateralLayer.lineWidth = 3
        quadrilateralLayer.lineJoin = .round
        quadrilateralLayer.shadowColor = UIColor.black.cgColor
        quadrilateralLayer.shadowOpacity = 0.22
        quadrilateralLayer.shadowRadius = 5
        layer.addSublayer(quadrilateralLayer)

        gutterLayer.fillColor = UIColor.clear.cgColor
        gutterLayer.strokeColor = UIColor.systemYellow.cgColor
        gutterLayer.lineWidth = 2
        gutterLayer.lineDashPattern = [7, 5]
        layer.addSublayer(gutterLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(90)
        {
            connection.videoRotationAngle = 90
        }
        quadrilateralLayer.frame = bounds
        gutterLayer.frame = bounds
        redrawOverlay()
    }

    func updateOverlay(
        detection: LiveRectangleDetection?,
        gutterRatio: CGFloat?
    ) {
        self.detection = detection
        self.gutterRatio = gutterRatio
        redrawOverlay()
    }

    private func redrawOverlay() {
        guard let detection else {
            quadrilateralLayer.path = nil
            gutterLayer.path = nil
            accessibilityValue = "문서를 찾는 중"
            return
        }

        let quadrilateral = detection.quadrilateral
        let topLeft = previewPoint(for: quadrilateral.topLeft)
        let topRight = previewPoint(for: quadrilateral.topRight)
        let bottomRight = previewPoint(for: quadrilateral.bottomRight)
        let bottomLeft = previewPoint(for: quadrilateral.bottomLeft)

        let outline = UIBezierPath()
        outline.move(to: topLeft)
        outline.addLine(to: topRight)
        outline.addLine(to: bottomRight)
        outline.addLine(to: bottomLeft)
        outline.close()
        quadrilateralLayer.path = outline.cgPath
        quadrilateralLayer.strokeColor = (
            detection.isStable ? UIColor.systemGreen : UIColor.systemBlue
        ).cgColor

        if let gutterRatio {
            let topGutter = NormalizedPoint.interpolate(
                from: quadrilateral.topLeft,
                to: quadrilateral.topRight,
                amount: gutterRatio
            )
            let bottomGutter = NormalizedPoint.interpolate(
                from: quadrilateral.bottomLeft,
                to: quadrilateral.bottomRight,
                amount: gutterRatio
            )
            let gutterPath = UIBezierPath()
            gutterPath.move(to: previewPoint(for: topGutter))
            gutterPath.addLine(to: previewPoint(for: bottomGutter))
            gutterLayer.path = gutterPath.cgPath
        } else {
            gutterLayer.path = nil
        }

        let percent = Int((detection.stabilityProgress * 100).rounded())
        accessibilityValue = detection.isStable
            ? "문서가 안정됨"
            : "문서 안정화 \(percent)퍼센트"
    }

    private func previewPoint(for point: NormalizedPoint) -> CGPoint {
        // Vision uses a lower-left origin; capture-device points use top-left.
        let captureDevicePoint = CGPoint(x: point.x, y: 1 - point.y)
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: captureDevicePoint)
    }
}

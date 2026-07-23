import AVFoundation
import UIKit

final class ScannerPreviewView: UIView {
  private let guideLayer = CAShapeLayer()
  private let quadrilateralLayer = CAShapeLayer()
  private let gutterLayer = CAShapeLayer()
  private var detection: LiveRectangleDetection?
  private var gutterRatio: CGFloat?
  private var videoRotationAngle: CGFloat = 90

  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

  var previewLayer: AVCaptureVideoPreviewLayer {
    guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
      preconditionFailure("ScannerPreviewView requires AVCaptureVideoPreviewLayer")
    }
    return previewLayer
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    isAccessibilityElement = true
    accessibilityLabel = "문서 카메라 미리보기"

    guideLayer.fillColor = UIColor.clear.cgColor
    guideLayer.strokeColor = UIColor.white.withAlphaComponent(0.7).cgColor
    guideLayer.lineWidth = 2
    guideLayer.lineDashPattern = [9, 7]
    layer.addSublayer(guideLayer)

    quadrilateralLayer.fillColor = UIColor.clear.cgColor
    quadrilateralLayer.lineWidth = 3
    quadrilateralLayer.lineJoin = .round
    quadrilateralLayer.shadowColor = UIColor.black.cgColor
    quadrilateralLayer.shadowOpacity = 0.24
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

  override func layoutSubviews() {
    super.layoutSubviews()
    if let connection = previewLayer.connection,
      connection.isVideoRotationAngleSupported(videoRotationAngle)
    {
      connection.videoRotationAngle = videoRotationAngle
    }
    quadrilateralLayer.frame = bounds
    gutterLayer.frame = bounds
    guideLayer.frame = bounds
    redrawOverlay()
  }

  func attach(session: AVCaptureSession) {
    previewLayer.session = session
    previewLayer.videoGravity = .resizeAspectFill
  }

  func update(detection: LiveRectangleDetection?, gutterRatio: CGFloat?) {
    self.detection = detection
    self.gutterRatio = gutterRatio
    redrawOverlay()
  }

  func updateVideoRotationAngle(_ angle: CGFloat) {
    videoRotationAngle = angle
    if let connection = previewLayer.connection,
      connection.isVideoRotationAngleSupported(angle)
    {
      connection.videoRotationAngle = angle
    }
    redrawOverlay()
  }

  private func redrawOverlay() {
    guard let detection else {
      quadrilateralLayer.path = nil
      gutterLayer.path = nil
      let guideRect = bounds.insetBy(dx: bounds.width * 0.055, dy: bounds.height * 0.075)
      guideLayer.path = UIBezierPath(roundedRect: guideRect, cornerRadius: 18).cgPath
      accessibilityValue = "문서를 찾는 중"
      return
    }

    guideLayer.path = nil

    let quadrilateral = detection.quadrilateral
    let outline = UIBezierPath()
    outline.move(to: previewPoint(for: quadrilateral.topLeft))
    outline.addLine(to: previewPoint(for: quadrilateral.topRight))
    outline.addLine(to: previewPoint(for: quadrilateral.bottomRight))
    outline.addLine(to: previewPoint(for: quadrilateral.bottomLeft))
    outline.close()
    quadrilateralLayer.path = outline.cgPath
    quadrilateralLayer.strokeColor =
      (detection.isStable ? UIColor.systemGreen : UIColor.systemBlue).cgColor

    if let gutterRatio {
      let top = NormalizedPoint.interpolate(
        from: quadrilateral.topLeft,
        to: quadrilateral.topRight,
        amount: gutterRatio
      )
      let bottom = NormalizedPoint.interpolate(
        from: quadrilateral.bottomLeft,
        to: quadrilateral.bottomRight,
        amount: gutterRatio
      )
      let gutter = UIBezierPath()
      gutter.move(to: previewPoint(for: top))
      gutter.addLine(to: previewPoint(for: bottom))
      gutterLayer.path = gutter.cgPath
    } else {
      gutterLayer.path = nil
    }

    let stability = Int((detection.stabilityProgress * 100).rounded())
    accessibilityValue =
      detection.isStable
      ? "문서가 안정됨"
      : "문서 안정화 \(stability)퍼센트"
  }

  private func previewPoint(for point: NormalizedPoint) -> CGPoint {
    // Vision reports points in the explicitly oriented image while
    // AVCaptureVideoPreviewLayer converts from sensor-native capture-device
    // coordinates. Undo the image orientation first, then flip Vision's
    // lower-left origin to AVFoundation's upper-left origin.
    let orientation = ScannerFrameOrientation(
      videoRotationAngle: videoRotationAngle
    )
    let rawPoint = orientation.rawVisionPoint(fromOriented: point)
    return previewLayer.layerPointConverted(
      fromCaptureDevicePoint: CGPoint(x: rawPoint.x, y: 1 - rawPoint.y)
    )
  }
}

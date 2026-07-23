import Foundation
import ImageIO
import PencilKit
import UIKit

enum SignatureMarkupError: LocalizedError, Equatable {
  case imageDecodingFailed
  case emptyDrawing
  case invalidCanvasSize
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .imageDecodingFailed:
      "페이지 이미지를 읽지 못했습니다."
    case .emptyDrawing:
      "저장할 서명이나 필기가 없습니다."
    case .invalidCanvasSize:
      "서명 영역의 크기가 올바르지 않습니다."
    case .encodingFailed:
      "서명이 포함된 JPEG를 만들지 못했습니다."
    }
  }
}

enum SignatureMarkupOutcome: Equatable {
  case saved(Data)
  case cancelled
}

/// Pure composition helpers kept separate from persistence. The caller writes
/// returned JPEG data as the page's enhanced image, preserving the original.
enum SignatureMarkupComposer {
  static let defaultMaximumOutputDimension = 3_072

  static func pixelSize(from imageData: Data) throws -> CGSize {
    guard
      let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      throw SignatureMarkupError.imageDecodingFailed
    }

    let orientationValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let swapsDimensions = [5, 6, 7, 8].contains(orientationValue)
    let pixelWidth = swapsDimensions ? height.doubleValue : width.doubleValue
    let pixelHeight = swapsDimensions ? width.doubleValue : height.doubleValue
    guard pixelWidth > 0, pixelHeight > 0 else {
      throw SignatureMarkupError.imageDecodingFailed
    }
    return CGSize(width: pixelWidth, height: pixelHeight)
  }

  static func previewImage(
    from imageData: Data,
    maximumDimension: Int = 2_048
  ) throws -> UIImage {
    UIImage(
      cgImage: try downsampledImage(
        from: imageData,
        maximumDimension: maximumDimension
      ))
  }

  static func compositeJPEG(
    sourceImageData: Data,
    drawing: PKDrawing,
    canvasSize: CGSize,
    compressionQuality: CGFloat = 0.94,
    maximumOutputDimension: Int = defaultMaximumOutputDimension
  ) throws -> Data {
    guard !drawing.strokes.isEmpty, !drawing.bounds.isEmpty else {
      throw SignatureMarkupError.emptyDrawing
    }
    guard canvasSize.width > 0, canvasSize.height > 0 else {
      throw SignatureMarkupError.invalidCanvasSize
    }

    let maximumDimension = min(max(maximumOutputDimension, 1_024), 4_096)
    let source = try downsampledImage(
      from: sourceImageData,
      maximumDimension: maximumDimension
    )
    let outputSize = CGSize(width: source.width, height: source.height)
    let horizontalScale = outputSize.width / canvasSize.width
    let verticalScale = outputSize.height / canvasSize.height
    let drawingScale = min(horizontalScale, verticalScale)
    guard drawingScale.isFinite, drawingScale > 0 else {
      throw SignatureMarkupError.invalidCanvasSize
    }

    return try autoreleasepool {
      let overlay = drawing.image(
        from: CGRect(origin: .zero, size: canvasSize),
        scale: drawingScale
      )
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
      let quality = min(max(compressionQuality, 0.65), 1)
      let data = renderer.jpegData(withCompressionQuality: quality) { _ in
        UIImage(cgImage: source).draw(
          in: CGRect(origin: .zero, size: outputSize)
        )
        overlay.draw(in: CGRect(origin: .zero, size: outputSize))
      }
      guard !data.isEmpty else { throw SignatureMarkupError.encodingFailed }
      return data
    }
  }

  static func rescaledDrawing(
    _ drawing: PKDrawing,
    from oldSize: CGSize,
    to newSize: CGSize
  ) -> PKDrawing {
    guard
      oldSize.width > 0,
      oldSize.height > 0,
      newSize.width > 0,
      newSize.height > 0
    else {
      return drawing
    }
    return drawing.transformed(
      using: CGAffineTransform(
        scaleX: newSize.width / oldSize.width,
        y: newSize.height / oldSize.height
      ))
  }

  private static func downsampledImage(
    from imageData: Data,
    maximumDimension: Int
  ) throws -> CGImage {
    guard
      let source = CGImageSourceCreateWithData(
        imageData as CFData,
        [
          kCGImageSourceShouldCache: false
        ] as CFDictionary)
    else {
      throw SignatureMarkupError.imageDecodingFailed
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        options as CFDictionary
      )
    else {
      throw SignatureMarkupError.imageDecodingFailed
    }
    return image
  }
}

/// PencilKit editor that returns a flattened JPEG only after a non-empty
/// drawing is explicitly saved. It never writes to the repository itself.
@MainActor
final class SignatureMarkupViewController: UIViewController, PKCanvasViewDelegate {
  typealias Completion = (SignatureMarkupOutcome) -> Void

  private let sourceImageData: Data
  private let sourcePixelSize: CGSize
  private let compressionQuality: CGFloat
  private let maximumOutputDimension: Int
  private let completion: Completion

  private let instructionsLabel = UILabel()
  private let workArea = UIView()
  private let markupSurface = UIView()
  private let imageView = UIImageView()
  private let canvasView = PKCanvasView()
  private let undoButton = UIButton(type: .system)
  private let eraserButton = UIButton(type: .system)
  private let activityIndicator = UIActivityIndicatorView(style: .medium)

  private var lastCanvasSize = CGSize.zero
  private var isEraserActive = false
  private var isSaving = false
  private var didComplete = false

  init(
    sourceImageData: Data,
    compressionQuality: CGFloat = 0.94,
    maximumOutputDimension: Int = SignatureMarkupComposer.defaultMaximumOutputDimension,
    completion: @escaping Completion
  ) throws {
    self.sourceImageData = sourceImageData
    sourcePixelSize = try SignatureMarkupComposer.pixelSize(from: sourceImageData)
    self.compressionQuality = compressionQuality
    self.maximumOutputDimension = maximumOutputDimension
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
    title = "서명"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    configureNavigation()
    configureViews()
    configureLayout()
    loadPreview()
    updateControls()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let fittedFrame = aspectFitRect(contentSize: sourcePixelSize, in: workArea.bounds)
    guard fittedFrame.width > 0, fittedFrame.height > 0 else { return }

    let newSize = fittedFrame.size
    if lastCanvasSize.width > 0,
      lastCanvasSize.height > 0,
      abs(lastCanvasSize.width - newSize.width) > 0.5
        || abs(lastCanvasSize.height - newSize.height) > 0.5
    {
      canvasView.drawing = SignatureMarkupComposer.rescaledDrawing(
        canvasView.drawing,
        from: lastCanvasSize,
        to: newSize
      )
    }

    markupSurface.frame = fittedFrame
    imageView.frame = markupSurface.bounds
    canvasView.frame = markupSurface.bounds
    canvasView.contentSize = newSize
    lastCanvasSize = newSize
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if isMovingFromParent || navigationController?.isBeingDismissed == true, !didComplete {
      completeOnce(.cancelled)
    }
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    updateControls()
  }

  private func configureNavigation() {
    let cancel = UIBarButtonItem(
      title: "취소",
      style: .plain,
      target: self,
      action: #selector(cancelTapped)
    )
    cancel.accessibilityIdentifier = "signature.cancel"
    navigationItem.leftBarButtonItem = cancel

    let save = UIBarButtonItem(
      title: "저장",
      style: .done,
      target: self,
      action: #selector(saveTapped)
    )
    save.accessibilityIdentifier = "signature.save"
    navigationItem.rightBarButtonItem = save
  }

  private func configureViews() {
    instructionsLabel.font = .preferredFont(forTextStyle: .footnote)
    instructionsLabel.adjustsFontForContentSizeCategory = true
    instructionsLabel.textColor = .secondaryLabel
    instructionsLabel.textAlignment = .center
    instructionsLabel.numberOfLines = 0
    instructionsLabel.text = "Apple Pencil 또는 손가락으로 서명하세요. 원본 이미지는 유지됩니다."
    instructionsLabel.accessibilityIdentifier = "signature.instructions"

    workArea.backgroundColor = .black
    workArea.clipsToBounds = true
    workArea.layer.cornerRadius = 14
    workArea.layer.cornerCurve = .continuous

    markupSurface.backgroundColor = .white
    markupSurface.clipsToBounds = true
    workArea.addSubview(markupSurface)

    imageView.contentMode = .scaleToFill
    imageView.backgroundColor = .white
    imageView.isAccessibilityElement = true
    imageView.accessibilityLabel = "서명을 추가할 스캔 페이지"
    imageView.accessibilityIdentifier = "signature.preview"
    markupSurface.addSubview(imageView)

    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.isScrollEnabled = false
    canvasView.bounces = false
    canvasView.drawingPolicy = .anyInput
    canvasView.tool = PKInkingTool(.pen, color: .label, width: 3.5)
    canvasView.delegate = self
    canvasView.accessibilityLabel = "서명 및 필기 영역"
    canvasView.accessibilityHint = "Apple Pencil 또는 손가락으로 그립니다."
    canvasView.accessibilityIdentifier = "signature.canvas"
    markupSurface.addSubview(canvasView)

    configureToolbarButton(
      undoButton,
      title: "실행 취소",
      image: "arrow.uturn.backward",
      identifier: "signature.undo",
      action: #selector(undoTapped)
    )
    configureToolbarButton(
      eraserButton,
      title: "지우개",
      image: "eraser",
      identifier: "signature.eraser",
      action: #selector(eraserTapped)
    )
    activityIndicator.hidesWhenStopped = true
    activityIndicator.accessibilityIdentifier = "signature.saving"
  }

  private func configureLayout() {
    instructionsLabel.translatesAutoresizingMaskIntoConstraints = false
    workArea.translatesAutoresizingMaskIntoConstraints = false

    let toolbar = UIStackView(arrangedSubviews: [undoButton, eraserButton, activityIndicator])
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.axis = .horizontal
    toolbar.alignment = .center
    toolbar.distribution = .fillEqually
    toolbar.spacing = 10
    toolbar.isLayoutMarginsRelativeArrangement = true
    toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 8,
      leading: 16,
      bottom: 8,
      trailing: 16
    )
    toolbar.backgroundColor = .secondarySystemBackground

    view.addSubview(instructionsLabel)
    view.addSubview(workArea)
    view.addSubview(toolbar)

    NSLayoutConstraint.activate([
      instructionsLabel.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor,
        constant: 10
      ),
      instructionsLabel.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor,
        constant: 18
      ),
      instructionsLabel.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -18
      ),

      workArea.topAnchor.constraint(equalTo: instructionsLabel.bottomAnchor, constant: 10),
      workArea.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor,
        constant: 12
      ),
      workArea.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -12
      ),
      workArea.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -10),

      toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),

      undoButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      eraserButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
  }

  private func loadPreview() {
    let data = sourceImageData
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let preview = try? SignatureMarkupComposer.previewImage(from: data)
      DispatchQueue.main.async {
        self?.imageView.image = preview
      }
    }
  }

  private func configureToolbarButton(
    _ button: UIButton,
    title: String,
    image: String,
    identifier: String,
    action: Selector
  ) {
    var configuration = UIButton.Configuration.tinted()
    configuration.title = title
    configuration.image = UIImage(systemName: image)
    configuration.imagePadding = 7
    configuration.cornerStyle = .medium
    button.configuration = configuration
    button.accessibilityIdentifier = identifier
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  private func updateControls() {
    let hasDrawing = !canvasView.drawing.strokes.isEmpty
    undoButton.isEnabled = !isSaving && hasDrawing
    eraserButton.isEnabled = !isSaving && hasDrawing
    navigationItem.leftBarButtonItem?.isEnabled = !isSaving
    navigationItem.rightBarButtonItem?.isEnabled = !isSaving && hasDrawing
    eraserButton.configuration?.baseBackgroundColor =
      isEraserActive
      ? .systemBlue.withAlphaComponent(0.22)
      : nil
    eraserButton.accessibilityValue = isEraserActive ? "켜짐" : "꺼짐"
  }

  @objc private func undoTapped() {
    canvasView.undoManager?.undo()
    updateControls()
  }

  @objc private func eraserTapped() {
    isEraserActive.toggle()
    canvasView.tool =
      isEraserActive
      ? PKEraserTool(.vector)
      : PKInkingTool(.pen, color: .label, width: 3.5)
    updateControls()
  }

  @objc private func cancelTapped() {
    completeOnce(.cancelled)
    close()
  }

  @objc private func saveTapped() {
    let drawing = canvasView.drawing
    let canvasSize = canvasView.bounds.size
    guard !drawing.strokes.isEmpty else { return }

    isSaving = true
    activityIndicator.startAnimating()
    navigationItem.rightBarButtonItem?.title = "저장 중…"
    updateControls()

    let sourceData = sourceImageData
    let quality = compressionQuality
    let maximumDimension = maximumOutputDimension
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Result {
          try SignatureMarkupComposer.compositeJPEG(
            sourceImageData: sourceData,
            drawing: drawing,
            canvasSize: canvasSize,
            compressionQuality: quality,
            maximumOutputDimension: maximumDimension
          )
        }
      }.value
      guard let self else { return }
      self.isSaving = false
      self.activityIndicator.stopAnimating()
      self.navigationItem.rightBarButtonItem?.title = "저장"
      self.updateControls()
      switch result {
      case .success(let data):
        self.completeOnce(.saved(data))
        self.close()
      case .failure(let error):
        self.presentError(error)
      }
    }
  }

  private func completeOnce(_ outcome: SignatureMarkupOutcome) {
    guard !didComplete else { return }
    didComplete = true
    completion(outcome)
  }

  private func close() {
    if navigationController?.presentingViewController != nil {
      navigationController?.dismiss(animated: true)
    } else if presentingViewController != nil {
      dismiss(animated: true)
    } else {
      navigationController?.popViewController(animated: true)
    }
  }

  private func presentError(_ error: Error) {
    let alert = UIAlertController(
      title: "서명을 저장하지 못했어요",
      message: error.localizedDescription,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "확인", style: .default))
    present(alert, animated: true)
  }

  private func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
    guard
      contentSize.width > 0,
      contentSize.height > 0,
      bounds.width > 0,
      bounds.height > 0
    else {
      return .zero
    }
    let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
    let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    return CGRect(
      x: bounds.midX - size.width / 2,
      y: bounds.midY - size.height / 2,
      width: size.width,
      height: size.height
    ).integral
  }
}

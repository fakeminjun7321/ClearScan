import PencilKit
import UIKit

enum SelectionEraserOutcome: Equatable {
  case saved(Data)
  case cancelled
}

enum SelectionEraserCanvasRenderer {
  static func maskImage(
    drawing: PKDrawing,
    canvasSize: CGSize,
    sourcePixelSize: CGSize,
    maximumOutputDimension: Int
  ) throws -> CGImage {
    guard !drawing.strokes.isEmpty, !drawing.bounds.isEmpty else {
      throw SelectionEraseError.emptySelection
    }
    guard
      canvasSize.width > 0,
      canvasSize.height > 0,
      sourcePixelSize.width > 0,
      sourcePixelSize.height > 0
    else {
      throw SelectionEraseError.invalidCanvasSize
    }

    let scaleToLimit = min(
      1,
      CGFloat(maximumOutputDimension) / max(sourcePixelSize.width, sourcePixelSize.height)
    )
    let targetSize = CGSize(
      width: sourcePixelSize.width * scaleToLimit,
      height: sourcePixelSize.height * scaleToLimit
    )
    let drawingScale = min(
      targetSize.width / canvasSize.width,
      targetSize.height / canvasSize.height
    )
    let image = drawing.image(
      from: CGRect(origin: .zero, size: canvasSize),
      scale: drawingScale
    )
    guard let mask = image.cgImage else {
      throw SelectionEraseError.renderingFailed
    }
    return mask
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
}

/// User-guided, deterministic selected-area restoration. The red PencilKit
/// overlay is a mask preview only; no semantic or generative AI claim is made.
@MainActor
final class SelectionEraserViewController: UIViewController, PKCanvasViewDelegate {
  typealias Completion = (SelectionEraserOutcome) -> Void

  private let sourceImageData: Data
  private let sourcePixelSize: CGSize
  private let maximumOutputDimension: Int
  private let processor: SelectionEraseProcessor
  private let completion: Completion

  private let instructionsLabel = UILabel()
  private let workArea = UIView()
  private let markupSurface = UIView()
  private let imageView = UIImageView()
  private let canvasView = PKCanvasView()
  private let undoButton = UIButton(type: .system)
  private let resetButton = UIButton(type: .system)
  private let previewButton = UIButton(type: .system)
  private let brushLabel = UILabel()
  private let brushSlider = UISlider()
  private let activityIndicator = UIActivityIndicatorView(style: .medium)

  private var basePreviewImage: UIImage?
  private var previewJPEGData: Data?
  private var previewDrawing: PKDrawing?
  private var lastCanvasSize = CGSize.zero
  private var isPreviewing = false
  private var isBusy = false
  private var didComplete = false

  init(
    sourceImageData: Data,
    maximumSelectionRatio: Double = 0.15,
    maximumOutputDimension: Int = 3_072,
    completion: @escaping Completion
  ) throws {
    self.sourceImageData = sourceImageData
    sourcePixelSize = try SignatureMarkupComposer.pixelSize(from: sourceImageData)
    self.maximumOutputDimension = min(max(maximumOutputDimension, 1_024), 4_096)
    processor = SelectionEraseProcessor(
      maximumSelectionRatio: maximumSelectionRatio,
      maximumOutputDimension: maximumOutputDimension
    )
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
    title = "선택 지우개"
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
    updateBrushTool()
    loadPreview()
    updateControls()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let fittedFrame = aspectFitRect(contentSize: sourcePixelSize, in: workArea.bounds)
    guard fittedFrame.width > 0, fittedFrame.height > 0 else { return }
    let newSize = fittedFrame.size

    let shouldRescale =
      lastCanvasSize.width > 0
      && lastCanvasSize.height > 0
      && (abs(lastCanvasSize.width - newSize.width) > 0.5
        || abs(lastCanvasSize.height - newSize.height) > 0.5)
    if shouldRescale {
      canvasView.drawing = SelectionEraserCanvasRenderer.rescaledDrawing(
        canvasView.drawing,
        from: lastCanvasSize,
        to: newSize
      )
      previewJPEGData = nil
      previewDrawing = nil
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
    previewJPEGData = nil
    previewDrawing = nil
    if isPreviewing {
      showEditingSurface()
    }
    updateControls()
  }

  private func configureNavigation() {
    let cancel = UIBarButtonItem(
      title: "취소",
      style: .plain,
      target: self,
      action: #selector(cancelTapped)
    )
    cancel.accessibilityIdentifier = "selectionEraser.cancel"
    navigationItem.leftBarButtonItem = cancel

    let save = UIBarButtonItem(
      title: "저장",
      style: .done,
      target: self,
      action: #selector(saveTapped)
    )
    save.accessibilityIdentifier = "selectionEraser.save"
    navigationItem.rightBarButtonItem = save
  }

  private func configureViews() {
    instructionsLabel.font = .preferredFont(forTextStyle: .footnote)
    instructionsLabel.adjustsFontForContentSizeCategory = true
    instructionsLabel.textColor = .secondaryLabel
    instructionsLabel.textAlignment = .center
    instructionsLabel.numberOfLines = 0
    instructionsLabel.text = "지울 부분만 붉게 칠하세요. 주변 종이색으로 기기 안에서 복원하며 원본은 유지됩니다."
    instructionsLabel.accessibilityIdentifier = "selectionEraser.instructions"

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
    imageView.accessibilityLabel = "선택 지우개 문서 미리보기"
    imageView.accessibilityIdentifier = "selectionEraser.previewImage"
    markupSurface.addSubview(imageView)

    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.isScrollEnabled = false
    canvasView.bounces = false
    canvasView.drawingPolicy = .anyInput
    canvasView.delegate = self
    canvasView.accessibilityLabel = "지울 영역 선택"
    canvasView.accessibilityHint = "Apple Pencil 또는 손가락으로 지울 영역을 칠합니다."
    canvasView.accessibilityIdentifier = "selectionEraser.canvas"
    markupSurface.addSubview(canvasView)

    configureButton(
      undoButton,
      title: "실행 취소",
      image: "arrow.uturn.backward",
      identifier: "selectionEraser.undo",
      action: #selector(undoTapped)
    )
    configureButton(
      resetButton,
      title: "초기화",
      image: "trash.slash",
      identifier: "selectionEraser.reset",
      action: #selector(resetTapped)
    )
    configureButton(
      previewButton,
      title: "결과 미리보기",
      image: "eye",
      identifier: "selectionEraser.preview",
      action: #selector(previewTapped)
    )

    brushLabel.font = .preferredFont(forTextStyle: .footnote)
    brushLabel.adjustsFontForContentSizeCategory = true
    brushLabel.textColor = .secondaryLabel
    brushLabel.setContentHuggingPriority(.required, for: .horizontal)
    brushLabel.accessibilityIdentifier = "selectionEraser.brushLabel"

    brushSlider.minimumValue = 12
    brushSlider.maximumValue = 96
    brushSlider.value = 42
    brushSlider.minimumValueImage = UIImage(systemName: "circle.fill")
    brushSlider.maximumValueImage = UIImage(systemName: "circle.inset.filled")
    brushSlider.accessibilityLabel = "선택 브러시 크기"
    brushSlider.accessibilityIdentifier = "selectionEraser.brushSize"
    brushSlider.addTarget(self, action: #selector(brushSizeChanged), for: .valueChanged)

    activityIndicator.hidesWhenStopped = true
    activityIndicator.accessibilityIdentifier = "selectionEraser.processing"
  }

  private func configureLayout() {
    instructionsLabel.translatesAutoresizingMaskIntoConstraints = false
    workArea.translatesAutoresizingMaskIntoConstraints = false

    let actionRow = UIStackView(arrangedSubviews: [undoButton, resetButton, previewButton])
    actionRow.axis = .horizontal
    actionRow.distribution = .fillEqually
    actionRow.spacing = 8

    let brushRow = UIStackView(arrangedSubviews: [brushLabel, brushSlider, activityIndicator])
    brushRow.axis = .horizontal
    brushRow.alignment = .center
    brushRow.spacing = 10

    let toolbar = UIStackView(arrangedSubviews: [actionRow, brushRow])
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.axis = .vertical
    toolbar.spacing = 8
    toolbar.isLayoutMarginsRelativeArrangement = true
    toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 8,
      leading: 14,
      bottom: 8,
      trailing: 14
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
      actionRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      brushSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
    ])
  }

  private func configureButton(
    _ button: UIButton,
    title: String,
    image: String,
    identifier: String,
    action: Selector
  ) {
    var configuration = UIButton.Configuration.tinted()
    configuration.title = title
    configuration.image = UIImage(systemName: image)
    configuration.imagePadding = 6
    configuration.cornerStyle = .medium
    button.configuration = configuration
    button.accessibilityIdentifier = identifier
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  private func loadPreview() {
    let data = sourceImageData
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let preview = try? SignatureMarkupComposer.previewImage(from: data)
      DispatchQueue.main.async {
        guard let self else { return }
        self.basePreviewImage = preview
        self.imageView.image = preview
      }
    }
  }

  private func updateBrushTool() {
    let width = CGFloat(brushSlider.value)
    canvasView.tool = PKInkingTool(
      .marker,
      color: UIColor.systemRed.withAlphaComponent(0.78),
      width: width
    )
    brushLabel.text = "브러시 \(Int(width))"
    brushSlider.accessibilityValue = "\(Int(width))포인트"
  }

  private func updateControls() {
    let hasSelection = !canvasView.drawing.strokes.isEmpty
    undoButton.isEnabled = !isBusy && !isPreviewing && hasSelection
    resetButton.isEnabled = !isBusy && hasSelection
    previewButton.isEnabled = !isBusy && hasSelection
    brushSlider.isEnabled = !isBusy && !isPreviewing
    canvasView.isUserInteractionEnabled = !isBusy && !isPreviewing
    navigationItem.leftBarButtonItem?.isEnabled = !isBusy
    navigationItem.rightBarButtonItem?.isEnabled = !isBusy && hasSelection
    previewButton.configuration?.title = isPreviewing ? "선택 수정" : "결과 미리보기"
    previewButton.configuration?.image = UIImage(systemName: isPreviewing ? "paintbrush" : "eye")
  }

  @objc private func undoTapped() {
    canvasView.undoManager?.undo()
    updateControls()
  }

  @objc private func resetTapped() {
    canvasView.drawing = PKDrawing()
    previewJPEGData = nil
    previewDrawing = nil
    showEditingSurface()
    updateControls()
  }

  @objc private func brushSizeChanged() {
    updateBrushTool()
  }

  @objc private func previewTapped() {
    if isPreviewing {
      showEditingSurface()
      updateControls()
      return
    }
    renderSelection { [weak self] data in
      guard let self else { return }
      self.previewJPEGData = data
      self.previewDrawing = self.canvasView.drawing
      self.imageView.image = UIImage(data: data)
      self.canvasView.isHidden = true
      self.isPreviewing = true
      self.updateControls()
    }
  }

  @objc private func cancelTapped() {
    completeOnce(.cancelled)
    close()
  }

  @objc private func saveTapped() {
    if let previewJPEGData, previewDrawing == canvasView.drawing {
      completeOnce(.saved(previewJPEGData))
      close()
      return
    }
    renderSelection { [weak self] data in
      guard let self else { return }
      self.completeOnce(.saved(data))
      self.close()
    }
  }

  private func renderSelection(onSuccess: @escaping (Data) -> Void) {
    let drawing = canvasView.drawing
    let canvasSize = canvasView.bounds.size
    let mask: CGImage
    do {
      mask = try SelectionEraserCanvasRenderer.maskImage(
        drawing: drawing,
        canvasSize: canvasSize,
        sourcePixelSize: sourcePixelSize,
        maximumOutputDimension: maximumOutputDimension
      )
    } catch {
      presentError(error)
      return
    }

    setBusy(true)
    let data = sourceImageData
    let processor = processor
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Result {
          try processor.process(
            sourceImageData: data,
            selectionMask: mask
          ).jpegData
        }
      }.value
      guard let self else { return }
      self.setBusy(false)
      switch result {
      case .success(let data):
        onSuccess(data)
      case .failure(let error):
        self.presentError(error)
      }
    }
  }

  private func setBusy(_ busy: Bool) {
    isBusy = busy
    if busy {
      activityIndicator.startAnimating()
      navigationItem.rightBarButtonItem?.title = "처리 중…"
    } else {
      activityIndicator.stopAnimating()
      navigationItem.rightBarButtonItem?.title = "저장"
    }
    updateControls()
  }

  private func showEditingSurface() {
    isPreviewing = false
    imageView.image = basePreviewImage
    canvasView.isHidden = false
  }

  private func completeOnce(_ outcome: SelectionEraserOutcome) {
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
      title: "선택 영역을 지우지 못했어요",
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

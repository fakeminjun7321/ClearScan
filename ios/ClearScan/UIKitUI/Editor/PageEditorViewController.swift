import UIKit

@MainActor
final class PageEditorViewController: UIViewController {
  var onPageDeleted: (() -> Void)?

  private let environment: UIKitAppEnvironment
  private let page: ScanPage
  private let imageView = UIImageView()
  private let activityIndicator = UIActivityIndicatorView(style: .large)
  private let statusLabel = UILabel()
  private var actionButtons: [UIButton] = []

  init(environment: UIKitAppEnvironment, page: ScanPage) {
    self.environment = environment
    self.page = page
    super.init(nibName: nil, bundle: nil)
    title = "\(page.sortIndex + 1)페이지 편집"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    configureMarkupActions()
    configureImageView()
    configureActions()
    configureActivityOverlay()
    loadCurrentImage()
  }

  private func configureMarkupActions() {
    let signatureItem = UIBarButtonItem(
      image: UIImage(systemName: "pencil.tip.crop.circle"),
      style: .plain,
      target: self,
      action: #selector(showSignatureEditor)
    )
    signatureItem.accessibilityLabel = "서명 및 필기"
    signatureItem.accessibilityIdentifier = "pageAction.signature"

    let eraserItem = UIBarButtonItem(
      image: UIImage(systemName: "eraser.line.dashed"),
      style: .plain,
      target: self,
      action: #selector(showSelectionEraser)
    )
    eraserItem.accessibilityLabel = "선택 지우개"
    eraserItem.accessibilityIdentifier = "pageAction.selectionEraser"
    navigationItem.rightBarButtonItems = [signatureItem, eraserItem]
  }

  private func configureImageView() {
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    imageView.backgroundColor = .black
    imageView.isAccessibilityElement = true
    imageView.accessibilityLabel = "편집 중인 스캔 페이지"
    view.addSubview(imageView)
  }

  private func configureActions() {
    let crop = actionButton(title: "자동 자르기", image: "crop", action: #selector(autoCrop))
    let rotate = actionButton(title: "회전", image: "rotate.right", action: #selector(rotatePage))
    let correction = actionButton(
      title: "AI 보정", image: "wand.and.stars", action: #selector(showAIEnhancement))
    let ocr = actionButton(title: "AI OCR", image: "text.viewfinder", action: #selector(runOCR))
    let delete = actionButton(title: "삭제", image: "trash", action: #selector(confirmDelete))
    let restore = actionButton(
      title: "원본 복원", image: "arrow.uturn.backward", action: #selector(restoreOriginal))
    delete.configuration?.baseForegroundColor = .systemRed
    actionButtons = [crop, rotate, correction, ocr, delete, restore]

    let firstRow = UIStackView(arrangedSubviews: [crop, rotate, correction])
    let secondRow = UIStackView(arrangedSubviews: [ocr, delete, restore])
    for row in [firstRow, secondRow] {
      row.axis = .horizontal
      row.distribution = .fillEqually
      row.spacing = 9
    }

    let actionPanel = UIStackView(arrangedSubviews: [firstRow, secondRow])
    actionPanel.translatesAutoresizingMaskIntoConstraints = false
    actionPanel.axis = .vertical
    actionPanel.spacing = 9
    actionPanel.isLayoutMarginsRelativeArrangement = true
    actionPanel.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 12,
      leading: 14,
      bottom: 12,
      trailing: 14
    )
    actionPanel.backgroundColor = .secondarySystemBackground
    view.addSubview(actionPanel)

    NSLayoutConstraint.activate([
      actionPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      actionPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      actionPanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      firstRow.heightAnchor.constraint(equalToConstant: 60),
      secondRow.heightAnchor.constraint(equalToConstant: 60),

      imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: actionPanel.topAnchor),
    ])
  }

  private func configureActivityOverlay() {
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.hidesWhenStopped = true
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .preferredFont(forTextStyle: .footnote)
    statusLabel.textColor = .white
    statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
    statusLabel.layer.cornerRadius = 10
    statusLabel.clipsToBounds = true
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 2
    statusLabel.isHidden = true

    imageView.addSubview(activityIndicator)
    imageView.addSubview(statusLabel)
    NSLayoutConstraint.activate([
      activityIndicator.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      activityIndicator.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
      statusLabel.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 12),
      statusLabel.widthAnchor.constraint(lessThanOrEqualTo: imageView.widthAnchor, constant: -44),
      statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
    ])
  }

  private func actionButton(title: String, image: String, action: Selector) -> UIButton {
    var configuration = UIButton.Configuration.tinted()
    configuration.title = title
    configuration.image = UIImage(systemName: image)
    configuration.imagePlacement = .top
    configuration.imagePadding = 5
    configuration.cornerStyle = .medium
    let button = UIButton(configuration: configuration)
    button.accessibilityIdentifier = "pageAction.\(title)"
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  private func loadCurrentImage() {
    let path = page.preferredImagePath
    let imageStore = environment.imageStore
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let image = (try? imageStore.data(for: path)).flatMap(UIImage.init(data:))
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.imageView.image = image
        self.imageView.accessibilityValue = self.page.enhancedImagePath == nil ? "원본" : "보정본"
      }
    }
  }

  @objc private func autoCrop() {
    performImageEdit(status: "문서 테두리를 찾는 중…") { service, data in
      try service.automaticallyCroppedData(from: data)
    }
  }

  @objc private func rotatePage() {
    let sheet = UIAlertController(title: "페이지 회전", message: nil, preferredStyle: .actionSheet)
    sheet.addAction(
      UIAlertAction(title: "왼쪽으로 90°", style: .default) { [weak self] _ in
        self?.performRotation(.left)
      })
    sheet.addAction(
      UIAlertAction(title: "오른쪽으로 90°", style: .default) { [weak self] _ in
        self?.performRotation(.right)
      })
    sheet.addAction(UIAlertAction(title: "취소", style: .cancel))
    sheet.popoverPresentationController?.sourceView = actionButtons[1]
    sheet.popoverPresentationController?.sourceRect = actionButtons[1].bounds
    present(sheet, animated: true)
  }

  @objc private func showAIEnhancement() {
    let controller = AIEnhancementViewController(environment: environment, page: page)
    controller.onPageChanged = { [weak self] in
      self?.loadCurrentImage()
    }
    navigationController?.pushViewController(controller, animated: true)
  }

  @objc private func showSignatureEditor() {
    setBusy(true, status: "서명 편집기를 준비하는 중…")
    let path = page.preferredImagePath
    let imageStore = environment.imageStore

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try imageStore.data(for: path) }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.setBusy(false)
        do {
          let sourceData = try result.get()
          let controller = try SignatureMarkupViewController(
            sourceImageData: sourceData
          ) { [weak self] outcome in
            guard let self else { return }
            guard case .saved(let data) = outcome else { return }
            do {
              try self.environment.repository.updateEnhancedImage(for: self.page, data: data)
              self.loadCurrentImage()
            } catch {
              self.presentError(error, title: "서명을 저장하지 못했어요")
            }
          }
          self.present(
            UINavigationController(rootViewController: controller),
            animated: true
          )
        } catch {
          self.presentError(error, title: "서명 편집기를 열지 못했어요")
        }
      }
    }
  }

  @objc private func showSelectionEraser() {
    setBusy(true, status: "선택 지우개를 준비하는 중…")
    let path = page.preferredImagePath
    let imageStore = environment.imageStore

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try imageStore.data(for: path) }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.setBusy(false)
        do {
          let sourceData = try result.get()
          let controller = try SelectionEraserViewController(
            sourceImageData: sourceData
          ) { [weak self] outcome in
            guard let self else { return }
            guard case .saved(let data) = outcome else { return }
            do {
              try self.environment.repository.updateEnhancedImage(for: self.page, data: data)
              self.loadCurrentImage()
            } catch {
              self.presentError(error, title: "지우개 결과를 저장하지 못했어요")
            }
          }
          self.present(
            UINavigationController(rootViewController: controller),
            animated: true
          )
        } catch {
          self.presentError(error, title: "선택 지우개를 열지 못했어요")
        }
      }
    }
  }

  @objc private func runOCR() {
    setBusy(true, status: "기기에서 글자를 읽는 중…")
    let path = page.preferredImagePath
    let imageStore = environment.imageStore
    let pageEditor = environment.pageEditor
    let documentAI = environment.documentAI

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        let data = try imageStore.data(for: path)
        let image = try pageEditor.cgImage(from: data)
        let result = try documentAI.recognizeText(in: image)
        DispatchQueue.main.async {
          guard let self else { return }
          do {
            try self.environment.repository.updateRecognizedText(result.text, for: self.page)
            self.setBusy(false)
            self.presentOCRResult(result)
          } catch {
            self.finishWithError(error, title: "OCR 결과를 저장하지 못했어요")
          }
        }
      } catch {
        DispatchQueue.main.async {
          self?.finishWithError(error, title: "글자를 읽지 못했어요")
        }
      }
    }
  }

  @objc private func confirmDelete() {
    let alert = UIAlertController(
      title: "페이지를 삭제할까요?",
      message: "이 작업은 되돌릴 수 없습니다.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "취소", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "삭제", style: .destructive) { [weak self] _ in
        guard let self else { return }
        do {
          try self.environment.repository.deletePage(self.page)
          self.onPageDeleted?()
        } catch {
          self.presentError(error, title: "페이지를 삭제하지 못했어요")
        }
      })
    present(alert, animated: true)
  }

  @objc private func restoreOriginal() {
    do {
      try environment.repository.resetEnhancedImage(for: page)
      loadCurrentImage()
      presentMessage(title: "원본으로 복원했어요", message: "보정본만 제거하고 원본 파일은 유지했습니다.")
    } catch {
      presentError(error, title: "원본을 복원하지 못했어요")
    }
  }

  private func performRotation(_ rotation: PageRotation) {
    performImageEdit(status: "페이지를 회전하는 중…") { service, data in
      try service.rotatedData(from: data, rotation: rotation)
    }
  }

  private func performImageEdit(
    status: String,
    operation: @escaping (DocumentPageEditingService, Data) throws -> Data
  ) {
    setBusy(true, status: status)
    let path = page.preferredImagePath
    let imageStore = environment.imageStore
    let pageEditor = environment.pageEditor

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        let source = try imageStore.data(for: path)
        let output = try operation(pageEditor, source)
        DispatchQueue.main.async {
          guard let self else { return }
          do {
            try self.environment.repository.updateEnhancedImage(for: self.page, data: output)
            self.setBusy(false)
            self.loadCurrentImage()
          } catch {
            self.finishWithError(error, title: "편집 결과를 저장하지 못했어요")
          }
        }
      } catch {
        DispatchQueue.main.async {
          self?.finishWithError(error, title: "페이지를 편집하지 못했어요")
        }
      }
    }
  }

  private func setBusy(_ busy: Bool, status: String? = nil) {
    for button in actionButtons {
      button.isEnabled = !busy
    }
    navigationItem.hidesBackButton = busy
    for item in navigationItem.rightBarButtonItems ?? [] {
      item.isEnabled = !busy
    }
    if busy {
      statusLabel.text = status.map { "  \($0)  " }
      statusLabel.isHidden = false
      activityIndicator.startAnimating()
    } else {
      statusLabel.isHidden = true
      activityIndicator.stopAnimating()
    }
  }

  private func finishWithError(_ error: Error, title: String) {
    setBusy(false)
    presentError(error, title: title)
  }

  private func presentOCRResult(_ result: DocumentOCRResult) {
    let resultController = OCRResultViewController(
      result: result,
      onSave: { [weak self] editedText in
        guard let self else { return }
        try self.environment.repository.updateRecognizedText(editedText, for: self.page)
      },
      onUseSuggestedTitle: page.document == nil
        ? nil
        : { [weak self] suggestedTitle in
          guard let self, let document = self.page.document else { return }
          try self.environment.repository.renameDocument(document, title: suggestedTitle)
        }
    )
    present(UINavigationController(rootViewController: resultController), animated: true)
  }
}

private final class OCRResultViewController: UIViewController {
  private let result: DocumentOCRResult
  private let onSave: (String) throws -> Void
  private let onUseSuggestedTitle: ((String) throws -> Void)?
  private let textView = UITextView()
  private let suggestedTitleButton = UIButton(type: .system)

  init(
    result: DocumentOCRResult,
    onSave: @escaping (String) throws -> Void,
    onUseSuggestedTitle: ((String) throws -> Void)?
  ) {
    self.result = result
    self.onSave = onSave
    self.onUseSuggestedTitle = onUseSuggestedTitle
    super.init(nibName: nil, bundle: nil)
    title = "OCR 텍스트 편집"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(close)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "저장",
      style: .done,
      target: self,
      action: #selector(save)
    )
    navigationItem.rightBarButtonItem?.accessibilityIdentifier = "saveOCRText"

    let confidence = UILabel()
    confidence.translatesAutoresizingMaskIntoConstraints = false
    confidence.font = .preferredFont(forTextStyle: .footnote)
    confidence.textColor = .secondaryLabel
    confidence.text = "인식 신뢰도 \(Int(result.averageConfidence * 100))% · 기기 내 처리"

    var titleConfiguration = UIButton.Configuration.tinted()
    titleConfiguration.image = UIImage(systemName: "textformat")
    titleConfiguration.imagePadding = 7
    titleConfiguration.cornerStyle = .medium
    if let suggestedTitle = result.suggestedTitle, onUseSuggestedTitle != nil {
      titleConfiguration.title = "“\(suggestedTitle)” 문서 제목으로 사용"
    } else {
      suggestedTitleButton.isHidden = true
    }
    suggestedTitleButton.configuration = titleConfiguration
    suggestedTitleButton.accessibilityIdentifier = "useOCRSuggestedTitle"
    suggestedTitleButton.addTarget(
      self,
      action: #selector(useSuggestedTitle),
      for: .touchUpInside
    )

    let summaryStack = UIStackView(arrangedSubviews: [confidence, suggestedTitleButton])
    summaryStack.translatesAutoresizingMaskIntoConstraints = false
    summaryStack.axis = .vertical
    summaryStack.spacing = 8

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.font = .preferredFont(forTextStyle: .body)
    textView.text = result.text
    textView.isEditable = true
    textView.isSelectable = true
    textView.keyboardDismissMode = .interactive
    textView.accessibilityIdentifier = "editableOCRText"

    view.addSubview(summaryStack)
    view.addSubview(textView)
    NSLayoutConstraint.activate([
      summaryStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      summaryStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      summaryStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      textView.topAnchor.constraint(equalTo: summaryStack.bottomAnchor, constant: 10),
      textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
  }

  @objc private func close() {
    dismiss(animated: true)
  }

  @objc private func save() {
    do {
      try onSave(textView.text)
      dismiss(animated: true)
    } catch {
      presentError(error, title: "편집한 텍스트를 저장하지 못했어요")
    }
  }

  @objc private func useSuggestedTitle() {
    guard
      let suggestedTitle = result.suggestedTitle,
      let onUseSuggestedTitle
    else { return }
    do {
      try onUseSuggestedTitle(suggestedTitle)
      var configuration = suggestedTitleButton.configuration
      configuration?.title = "문서 제목으로 사용했어요"
      configuration?.image = UIImage(systemName: "checkmark")
      suggestedTitleButton.configuration = configuration
      suggestedTitleButton.isEnabled = false
    } catch {
      presentError(error, title: "문서 제목을 바꾸지 못했어요")
    }
  }
}

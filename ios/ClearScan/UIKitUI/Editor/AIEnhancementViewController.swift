import UIKit

@MainActor
final class AIEnhancementViewController: UIViewController {
  var onPageChanged: (() -> Void)?

  private enum Operation: Sendable {
    case correction(ScanCorrectionPreset)
    case deblur
    case normalizeIllumination
    case removeEdgeFinger
    case removeRedAndBlueInk
    case dewarpBookPage
    case automaticPerspective
  }

  private enum EnhancementUIError: LocalizedError {
    case jpegEncodingFailed
    case bookCurveNotDetected

    var errorDescription: String? {
      switch self {
      case .jpegEncodingFailed:
        return "보정 결과를 저장 가능한 이미지로 만들지 못했습니다."
      case .bookCurveNotDetected:
        return "반복되는 글줄에서 안전하게 보정할 책 곡률을 찾지 못했습니다. 원본은 변경하지 않았습니다."
      }
    }
  }

  private struct Tool: Sendable {
    let id: String
    let title: String
    let summary: String
    let implementation: String
    let symbolName: String
    let operation: Operation
  }

  private static let tools: [Tool] = [
    Tool(
      id: "smartAuto",
      title: "스마트 자동",
      summary: "노이즈를 줄이고 글자 가장자리와 명암을 한 번에 정리해요.",
      implementation: "기기 내 일반 보정",
      symbolName: "wand.and.stars",
      operation: .correction(.smartAuto)
    ),
    Tool(
      id: "removeEdgeFinger",
      title: "손가락 지우기 (Beta)",
      summary: "페이지 가장자리의 손가락 후보만 보수적으로 찾아 지워요.",
      implementation: "기기 내 Vision AI · 애매하면 변경 안 함",
      symbolName: "hand.raised",
      operation: .removeEdgeFinger
    ),
    Tool(
      id: "normalizeIllumination",
      title: "그림자·조명 균일화",
      summary: "종이 위의 불균일한 조명과 완만한 그림자를 고르게 정리해요.",
      implementation: "기기 내 조명 분석·일반 보정",
      symbolName: "sun.max",
      operation: .normalizeIllumination
    ),
    Tool(
      id: "deblur",
      title: "흐림 보정",
      summary: "가벼운 흔들림과 초점 흐림을 분석해 글자 가장자리를 복원해요.",
      implementation: "기기 내 화질 분석·일반 보정",
      symbolName: "camera.metering.center.weighted",
      operation: .deblur
    ),
    Tool(
      id: "removeColorInk",
      title: "색 필기 지우기",
      summary: "종이 위의 빨강·파랑 필기만 찾아 주변 종이색으로 복원해요.",
      implementation: "기기 내 색상 분석 · 검은 필기 제외",
      symbolName: "eraser",
      operation: .removeRedAndBlueInk
    ),
    Tool(
      id: "documentTone",
      title: "문서 톤",
      summary: "밝기·대비·색감을 종이 문서에 맞게 조절해요.",
      implementation: "기기 내 일반 보정",
      symbolName: "doc.text.image",
      operation: .correction(.document)
    ),
    Tool(
      id: "blackAndWhite",
      title: "선명한 흑백",
      summary: "색을 제거해 글자와 배경의 대비를 높여요.",
      implementation: "기기 내 일반 보정",
      symbolName: "circle.lefthalf.filled",
      operation: .correction(.blackAndWhite)
    ),
    Tool(
      id: "dewarpBookPage",
      title: "책 곡률 펴기 (Beta)",
      summary: "책등 근처에서 휘어진 가로 글줄을 분석해 보수적으로 펴요.",
      implementation: "기기 내 곡률 분석 · 일반 3D 주름 제외",
      symbolName: "book.pages",
      operation: .dewarpBookPage
    ),
    Tool(
      id: "automaticPerspective",
      title: "자동 펴기 · 평면 문서",
      summary: "검출한 사각형을 기준으로 기울어진 평면 문서의 원근을 바로잡아요.",
      implementation: "Vision 사각형 검출 · 책 곡률 제외",
      symbolName: "viewfinder",
      operation: .automaticPerspective
    ),
  ]

  private let environment: UIKitAppEnvironment
  private let page: ScanPage
  private let explanationLabel = UILabel()
  private let previewContainer = UIView()
  private let imageView = UIImageView()
  private let activityIndicator = UIActivityIndicatorView(style: .large)
  private let comparisonControl = UISegmentedControl(items: ["원본", "미리보기"])
  private let statusLabel = UILabel()
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let restoreButton = UIButton(type: .system)
  private let applyButton = UIButton(type: .system)
  private var originalImage: UIImage?
  private var currentImage: UIImage?
  private var previewImage: UIImage?
  private var previewData: Data?
  private var selectedToolID: String?
  private var previewGenerationID: UUID?
  private var isBusy = false

  init(environment: UIKitAppEnvironment, page: ScanPage) {
    self.environment = environment
    self.page = page
    super.init(nibName: nil, bundle: nil)
    title = "AI 보정"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    configureNavigation()
    configurePreview()
    configureToolList()
    configureActions()
    configureLayout()
    loadSourceImages()
  }

  private func configureNavigation() {
    navigationItem.largeTitleDisplayMode = .never
    #if DEBUG
      let diagnosticsButton = UIBarButtonItem(
        image: UIImage(systemName: "stethoscope"),
        style: .plain,
        target: self,
        action: #selector(showDiagnostics)
      )
      diagnosticsButton.accessibilityLabel = "개발자 진단"
      diagnosticsButton.accessibilityIdentifier = "aiEnhancement.diagnostics"
      navigationItem.rightBarButtonItem = diagnosticsButton
    #endif
  }

  private func configurePreview() {
    explanationLabel.translatesAutoresizingMaskIntoConstraints = false
    explanationLabel.font = .preferredFont(forTextStyle: .footnote)
    explanationLabel.textColor = .secondaryLabel
    explanationLabel.numberOfLines = 2
    explanationLabel.text =
      "지금 기기에서 실제 동작하는 기능만 표시합니다. AI·Vision·일반 보정 방식을 항목마다 구분해요."

    previewContainer.translatesAutoresizingMaskIntoConstraints = false
    previewContainer.backgroundColor = .black
    previewContainer.layer.cornerRadius = 18
    previewContainer.clipsToBounds = true

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = true
    imageView.accessibilityLabel = "보정 미리보기"
    imageView.accessibilityIdentifier = "aiEnhancement.preview"

    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.hidesWhenStopped = true
    activityIndicator.color = .white

    previewContainer.addSubview(imageView)
    previewContainer.addSubview(activityIndicator)

    comparisonControl.translatesAutoresizingMaskIntoConstraints = false
    comparisonControl.selectedSegmentIndex = 1
    comparisonControl.accessibilityIdentifier = "aiEnhancement.comparison"
    comparisonControl.addTarget(self, action: #selector(comparisonChanged), for: .valueChanged)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .preferredFont(forTextStyle: .caption1)
    statusLabel.textColor = .secondaryLabel
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 2
    statusLabel.text = "기능을 선택하면 저장 전에 결과를 미리 볼 수 있어요."
    statusLabel.accessibilityIdentifier = "aiEnhancement.status"
  }

  private func configureToolList() {
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = .clear
    tableView.separatorInset = UIEdgeInsets(top: 0, left: 62, bottom: 0, right: 18)
    tableView.rowHeight = 82
    tableView.estimatedRowHeight = 82
    tableView.dataSource = self
    tableView.delegate = self
    tableView.accessibilityIdentifier = "aiEnhancement.tools"
  }

  private func configureActions() {
    var restoreConfiguration = UIButton.Configuration.tinted()
    restoreConfiguration.title = "원본 복원"
    restoreConfiguration.image = UIImage(systemName: "arrow.uturn.backward")
    restoreConfiguration.imagePadding = 7
    restoreConfiguration.cornerStyle = .large
    restoreButton.configuration = restoreConfiguration
    restoreButton.translatesAutoresizingMaskIntoConstraints = false
    restoreButton.accessibilityIdentifier = "aiEnhancement.restore"
    restoreButton.addTarget(self, action: #selector(restoreOriginal), for: .touchUpInside)

    var applyConfiguration = UIButton.Configuration.filled()
    applyConfiguration.title = "미리보기 적용"
    applyConfiguration.image = UIImage(systemName: "checkmark")
    applyConfiguration.imagePadding = 7
    applyConfiguration.cornerStyle = .large
    applyButton.configuration = applyConfiguration
    applyButton.translatesAutoresizingMaskIntoConstraints = false
    applyButton.accessibilityIdentifier = "aiEnhancement.apply"
    applyButton.isEnabled = false
    applyButton.addTarget(self, action: #selector(applyPreview), for: .touchUpInside)
  }

  private func configureLayout() {
    let buttonRow = UIStackView(arrangedSubviews: [restoreButton, applyButton])
    buttonRow.translatesAutoresizingMaskIntoConstraints = false
    buttonRow.axis = .horizontal
    buttonRow.distribution = .fillEqually
    buttonRow.spacing = 10

    view.addSubview(explanationLabel)
    view.addSubview(previewContainer)
    view.addSubview(comparisonControl)
    view.addSubview(statusLabel)
    view.addSubview(tableView)
    view.addSubview(buttonRow)

    let guide = view.readableContentGuide
    let preferredPreviewHeight = previewContainer.heightAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.heightAnchor,
      multiplier: 0.34
    )
    preferredPreviewHeight.priority = .defaultHigh

    NSLayoutConstraint.activate([
      explanationLabel.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor,
        constant: 10
      ),
      explanationLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      explanationLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor),

      previewContainer.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 10),
      previewContainer.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      previewContainer.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      preferredPreviewHeight,
      previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
      previewContainer.heightAnchor.constraint(lessThanOrEqualToConstant: 420),

      imageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

      activityIndicator.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
      activityIndicator.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),

      comparisonControl.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 8),
      comparisonControl.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      comparisonControl.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor),
      comparisonControl.widthAnchor.constraint(equalToConstant: 240),

      statusLabel.topAnchor.constraint(equalTo: comparisonControl.bottomAnchor, constant: 5),
      statusLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor),

      tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
      tableView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -8),

      buttonRow.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      buttonRow.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      buttonRow.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor,
        constant: -10
      ),
      buttonRow.heightAnchor.constraint(equalToConstant: 52),
    ])
  }

  private func loadSourceImages() {
    setBusy(true, status: "페이지를 불러오는 중…")
    let originalPath = page.originalImagePath
    let currentPath = page.preferredImagePath
    let imageStore = environment.imageStore
    let pageEditor = environment.pageEditor

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let original = (try? imageStore.data(for: originalPath)).flatMap(UIImage.init(data:))
      let currentData = try? imageStore.data(for: currentPath)
      let current = currentData.flatMap(UIImage.init(data:))
      let quality = currentData.flatMap { try? pageEditor.qualityAssessment(from: $0) }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.originalImage = original
        self.currentImage = current ?? original
        self.previewImage = nil
        self.previewData = nil
        self.applyButton.isEnabled = false
        self.setBusy(false, status: self.qualityStatus(quality))
        self.updateDisplayedImage()
      }
    }
  }

  private func qualityStatus(_ quality: DocumentImageQualityAssessment?) -> String {
    guard let quality else {
      return "기능을 선택하면 저장 전에 결과를 미리 볼 수 있어요."
    }
    guard quality.isReliable else {
      return "화질 분석: 글자 가장자리가 적어 흐림 정도를 판단하지 못했어요."
    }
    switch quality.blurSeverity {
    case .none:
      return "화질 분석: 흐림이 거의 없어요."
    case .mild:
      return "화질 분석: 약한 흐림 · 필요하면 흐림 보정을 사용해 보세요."
    case .moderate:
      return "화질 분석: 흐림 감지 · 흐림 보정을 추천해요."
    case .severe:
      return "화질 분석: 강한 흐림 · 재촬영하거나 흐림 보정을 사용해 보세요."
    }
  }

  private func makePreview(for tool: Tool) {
    let generationID = UUID()
    previewGenerationID = generationID
    selectedToolID = tool.id
    tableView.reloadData()
    setBusy(true, status: "\(tool.title) 미리보기를 만드는 중…")

    let sourcePath = page.preferredImagePath
    let imageStore = environment.imageStore
    let pageEditor = environment.pageEditor
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result<Data, Error> {
        let source = try imageStore.data(for: sourcePath)
        switch tool.operation {
        case .correction(let preset):
          return try pageEditor.correctionData(from: source, preset: preset)
        case .deblur:
          return try pageEditor.deblurredData(from: source)
        case .normalizeIllumination:
          let sourceImage = try pageEditor.cgImage(from: source)
          let resultImage = try DocumentIlluminationNormalizer().normalizedImage(sourceImage)
          return try Self.jpegData(from: resultImage)
        case .removeEdgeFinger:
          let sourceImage = try pageEditor.cgImage(from: source)
          let resultImage = try ConservativeFingerRemover().removeEdgeFinger(from: sourceImage)
          return try Self.jpegData(from: resultImage)
        case .removeRedAndBlueInk:
          let sourceImage = try pageEditor.cgImage(from: source)
          let resultImage = try ChromaticInkRemover().removeRedAndBlueInk(from: sourceImage)
          return try Self.jpegData(from: resultImage)
        case .dewarpBookPage:
          let sourceImage = try pageEditor.cgImage(from: source)
          let dewarper = BookPageDewarper()
          let candidates = BookPageGutterSide.allCases.map {
            dewarper.dewarp(sourceImage, gutterSide: $0)
          }
          guard
            let result =
              candidates
              .filter(\.wasApplied)
              .max(by: { $0.diagnostics.confidence < $1.diagnostics.confidence })
          else {
            throw EnhancementUIError.bookCurveNotDetected
          }
          return try Self.jpegData(from: result.image)
        case .automaticPerspective:
          return try pageEditor.automaticallyCroppedData(from: source)
        }
      }

      DispatchQueue.main.async { [weak self] in
        guard let self, self.previewGenerationID == generationID else { return }
        switch result {
        case .success(let data):
          guard let image = UIImage(data: data) else {
            self.finishPreviewWithError(DocumentPageEditError.imageDecodingFailed)
            return
          }
          self.previewData = data
          self.previewImage = image
          self.comparisonControl.selectedSegmentIndex = 1
          self.setBusy(false, status: "\(tool.title) 미리보기 준비됨 · 아직 저장되지 않았어요.")
          self.applyButton.isEnabled = true
          self.updateDisplayedImage()
        case .failure(let error):
          self.finishPreviewWithError(error)
        }
      }
    }
  }

  private func finishPreviewWithError(_ error: Error) {
    previewGenerationID = nil
    setBusy(false, status: "미리보기를 만들지 못했어요.")
    presentError(userFacingError(for: error), title: "이 기능을 적용하지 못했어요")
  }

  nonisolated private static func jpegData(from image: CGImage) throws -> Data {
    guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.94) else {
      throw EnhancementUIError.jpegEncodingFailed
    }
    return data
  }

  private func userFacingError(for error: Error) -> Error {
    let message: String
    switch error {
    case ConservativeFingerRemovalError.noForegroundInstances,
      ConservativeFingerRemovalError.noConservativeCandidate:
      message =
        "페이지 가장자리에서 안전하게 지울 수 있는 손가락을 찾지 못했어요. 문서 내용을 보호하기 위해 이미지를 변경하지 않았습니다."
    case ConservativeFingerRemovalError.combinedCandidateAreaTooLarge:
      message = "지울 영역이 너무 넓어 문서 내용을 보호하기 위해 적용하지 않았어요."
    case ChromaticInkRemovalError.noEligibleRedOrBlueInk:
      message = "지울 수 있는 빨강·파랑 필기를 찾지 못했어요."
    case ChromaticInkRemovalError.tooMuchColoredContent:
      message = "색 영역이 너무 넓어 인쇄된 그림을 보호하기 위해 적용하지 않았어요."
    default:
      return error
    }
    return NSError(
      domain: "ClearScan.AIEnhancement",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  private func setBusy(_ busy: Bool, status: String) {
    isBusy = busy
    tableView.isUserInteractionEnabled = !busy
    comparisonControl.isEnabled = !busy
    restoreButton.isEnabled = !busy
    applyButton.isEnabled = !busy && previewData != nil
    navigationItem.hidesBackButton = busy
    statusLabel.text = status
    if busy {
      activityIndicator.startAnimating()
    } else {
      activityIndicator.stopAnimating()
    }
  }

  private func updateDisplayedImage() {
    if comparisonControl.selectedSegmentIndex == 0 {
      imageView.image = originalImage
      imageView.accessibilityValue = "원본"
    } else {
      imageView.image = previewImage ?? currentImage
      imageView.accessibilityValue = previewImage == nil ? "현재 페이지" : "미리보기"
    }
  }

  @objc private func comparisonChanged() {
    updateDisplayedImage()
  }

  @objc private func applyPreview() {
    guard let previewData, let previewImage else { return }
    do {
      try environment.repository.updateEnhancedImage(for: page, data: previewData)
      currentImage = previewImage
      self.previewData = nil
      applyButton.isEnabled = false
      statusLabel.text = "미리보기를 페이지에 적용했어요."
      imageView.accessibilityValue = "적용된 보정본"
      onPageChanged?()
    } catch {
      presentError(error, title: "미리보기를 저장하지 못했어요")
    }
  }

  @objc private func restoreOriginal() {
    guard !isBusy else { return }
    do {
      try environment.repository.resetEnhancedImage(for: page)
      currentImage = originalImage
      previewImage = nil
      previewData = nil
      selectedToolID = nil
      comparisonControl.selectedSegmentIndex = 0
      applyButton.isEnabled = false
      statusLabel.text = "보정본을 제거하고 원본으로 복원했어요."
      tableView.reloadData()
      updateDisplayedImage()
      onPageChanged?()
    } catch {
      presentError(error, title: "원본으로 복원하지 못했어요")
    }
  }

  #if DEBUG
    @objc private func showDiagnostics() {
      navigationController?.pushViewController(
        EnhancementDiagnosticsViewController(),
        animated: true
      )
    }
  #endif
}

extension AIEnhancementViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    Self.tools.count
  }

  func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let identifier = "AIEnhancementToolCell"
    let cell =
      tableView.dequeueReusableCell(withIdentifier: identifier)
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
    let tool = Self.tools[indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = tool.title
    content.secondaryText = "\(tool.summary)\n\(tool.implementation)"
    content.secondaryTextProperties.numberOfLines = 2
    content.secondaryTextProperties.color = .secondaryLabel
    content.image = UIImage(systemName: tool.symbolName)
    content.imageProperties.tintColor = .systemBlue
    content.imageProperties.maximumSize = CGSize(width: 30, height: 30)
    cell.contentConfiguration = content
    cell.accessoryType = selectedToolID == tool.id ? .checkmark : .none
    cell.accessibilityIdentifier = "aiEnhancement.\(tool.id)"
    cell.accessibilityHint = "선택하면 저장 전에 미리보기를 만듭니다."
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard !isBusy else { return }
    makePreview(for: Self.tools[indexPath.row])
  }
}

#if DEBUG
  @MainActor
  private final class EnhancementDiagnosticsViewController: UITableViewController {
    private struct Diagnostic {
      let title: String
      let detail: String
    }

    private let diagnostics: [Diagnostic] = [
      Diagnostic(
        title: "더 펴기 · 책 곡률 보정",
        detail: "미지원 · 평면 문서 원근 보정만 있습니다. 곡면 메쉬 보정 API가 없습니다."
      ),
      Diagnostic(
        title: "검은 필기 지우기",
        detail: "미지원 · 현재 색 필기 지우기는 빨강·파랑만 대상으로 하며 검은 인쇄 글자와 필기를 구분하지 않습니다."
      ),
      Diagnostic(
        title: "AI 지우개",
        detail: "미지원 · 선택 영역 마스크와 생성형 인페인팅 API가 없습니다."
      ),
    ]

    init() {
      super.init(style: .insetGrouped)
      title = "개발자 진단"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
      super.viewDidLoad()
      tableView.rowHeight = UITableView.automaticDimension
      tableView.estimatedRowHeight = 88
      tableView.accessibilityIdentifier = "aiEnhancement.diagnosticList"
    }

    override func tableView(
      _ tableView: UITableView,
      numberOfRowsInSection section: Int
    ) -> Int {
      diagnostics.count
    }

    override func tableView(
      _ tableView: UITableView,
      cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
      let identifier = "EnhancementDiagnosticCell"
      let cell =
        tableView.dequeueReusableCell(withIdentifier: identifier)
        ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
      let diagnostic = diagnostics[indexPath.row]
      var content = cell.defaultContentConfiguration()
      content.text = diagnostic.title
      content.secondaryText = diagnostic.detail
      content.secondaryTextProperties.numberOfLines = 0
      content.secondaryTextProperties.color = .secondaryLabel
      cell.contentConfiguration = content
      cell.selectionStyle = .none
      cell.accessibilityIdentifier = "aiEnhancement.unsupported.\(indexPath.row)"
      return cell
    }

    override func tableView(
      _ tableView: UITableView,
      titleForHeaderInSection section: Int
    ) -> String? {
      "아직 지원하지 않는 항목"
    }
  }
#endif

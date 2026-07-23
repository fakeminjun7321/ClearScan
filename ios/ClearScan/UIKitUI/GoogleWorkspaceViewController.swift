import UIKit

/// Native Google Drive upload UI backed by ClearScan's SwiftData documents and FileManager images.
/// This screen does not treat opening a companion website as Google integration.
@MainActor
final class GoogleWorkspaceViewController: UIViewController, UITableViewDataSource,
  UITableViewDelegate
{
  private struct UploadAttempt {
    let selections: [ScanExportSelection]
    let format: GoogleWorkspaceUploadFormat
  }

  private var environment: UIKitAppEnvironment?
  private let workspaceService: GoogleWorkspaceServicing

  private var documents: [ScanDocument] = []
  private var selectedPageIDs = Set<UUID>()
  private var lastAttempt: UploadAttempt?
  private var lastUploadedURL: URL?
  private var isBusy = false

  private let configurationLabel = UILabel()
  private let accountLabel = UILabel()
  private let connectButton = UIButton(type: .system)
  private let signOutButton = UIButton(type: .system)
  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let selectionLabel = UILabel()
  private let pdfButton = UIButton(type: .system)
  private let docsButton = UIButton(type: .system)
  private let progressLabel = UILabel()
  private let progressView = UIProgressView(progressViewStyle: .default)
  private let retryButton = UIButton(type: .system)
  private let openResultButton = UIButton(type: .system)

  init(
    environment: UIKitAppEnvironment? = nil,
    workspaceService: GoogleWorkspaceServicing? = nil
  ) {
    self.environment = environment
    self.workspaceService = workspaceService ?? GoogleWorkspaceService()
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Google Drive"
    navigationItem.largeTitleDisplayMode = .always
    view.backgroundColor = .systemGroupedBackground
    configureViews()
    configureLayout()
    resolveEnvironmentIfNeeded()
    refreshConfigurationUI()
    reloadDocuments()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadDocuments()
  }

  func numberOfSections(in tableView: UITableView) -> Int {
    documents.count
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    documents[section].sortedPages.count
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    let document = documents[section]
    return "\(document.title) · \(document.pageCount)페이지"
  }

  func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "GooglePageCell", for: indexPath)
    let page = documents[indexPath.section].sortedPages[indexPath.row]
    var content = UIListContentConfiguration.subtitleCell()
    content.text = "\(indexPath.row + 1)페이지"
    let imageState = page.enhancedImagePath == nil ? "원본" : "보정본"
    let textState = page.recognizedText == nil ? nil : "기기 OCR 있음"
    content.secondaryText = [imageState, textState].compactMap { $0 }.joined(separator: " · ")
    content.image = UIImage(systemName: "doc.richtext")
    content.imageProperties.tintColor = .systemBlue
    cell.contentConfiguration = content
    cell.accessoryType = selectedPageIDs.contains(page.id) ? .checkmark : .none
    cell.accessibilityIdentifier = "google.page.\(page.id.uuidString)"
    cell.accessibilityTraits = selectedPageIDs.contains(page.id) ? [.button, .selected] : .button
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let page = documents[indexPath.section].sortedPages[indexPath.row]
    if selectedPageIDs.contains(page.id) {
      selectedPageIDs.remove(page.id)
    } else {
      selectedPageIDs.insert(page.id)
    }
    tableView.reloadRows(at: [indexPath], with: .none)
    updateSelectionUI()
  }

  private func configureViews() {
    configurationLabel.font = .preferredFont(forTextStyle: .footnote)
    configurationLabel.adjustsFontForContentSizeCategory = true
    configurationLabel.numberOfLines = 0

    accountLabel.font = .preferredFont(forTextStyle: .subheadline)
    accountLabel.adjustsFontForContentSizeCategory = true
    accountLabel.textColor = .secondaryLabel
    accountLabel.numberOfLines = 0

    configureButton(
      connectButton,
      title: "1. Google 계정 연결",
      imageName: "person.crop.circle.badge.checkmark",
      style: .filled,
      action: #selector(connectTapped)
    )
    connectButton.accessibilityIdentifier = "google.connect"

    configureButton(
      signOutButton,
      title: "연결 해제",
      imageName: "rectangle.portrait.and.arrow.right",
      style: .gray,
      action: #selector(signOutTapped)
    )
    signOutButton.accessibilityIdentifier = "google.signOut"

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = .clear
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "GooglePageCell")
    tableView.rowHeight = 64

    selectionLabel.font = .preferredFont(forTextStyle: .subheadline)
    selectionLabel.adjustsFontForContentSizeCategory = true
    selectionLabel.textColor = .secondaryLabel

    configureButton(
      pdfButton,
      title: "3. Drive에 PDF 업로드",
      imageName: "arrow.up.doc",
      style: .filled,
      action: #selector(uploadPDFTapped)
    )
    pdfButton.accessibilityIdentifier = "google.upload.pdf"

    configureButton(
      docsButton,
      title: "3. 편집 가능한 Google Docs 만들기",
      imageName: "doc.text.magnifyingglass",
      style: .tinted,
      action: #selector(uploadDocsTapped)
    )
    docsButton.accessibilityIdentifier = "google.upload.docs"

    progressLabel.font = .preferredFont(forTextStyle: .footnote)
    progressLabel.adjustsFontForContentSizeCategory = true
    progressLabel.textColor = .secondaryLabel
    progressLabel.numberOfLines = 0
    progressLabel.text = "1. 계정 연결 → 2. 페이지 선택 → 3. 형식 선택. 앱이 Google Drive API로 직접 업로드합니다."

    progressView.progress = 0
    progressView.accessibilityIdentifier = "google.upload.progress"

    configureButton(
      retryButton,
      title: "업로드 재시도",
      imageName: "arrow.clockwise",
      style: .tinted,
      action: #selector(retryTapped)
    )
    retryButton.accessibilityIdentifier = "google.retry"
    retryButton.isHidden = true

    configureButton(
      openResultButton,
      title: "업로드된 파일 열기",
      imageName: "arrow.up.forward.app",
      style: .gray,
      action: #selector(openUploadedFileTapped)
    )
    openResultButton.accessibilityIdentifier = "google.openUploadedFile"
    openResultButton.isHidden = true

    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "전체 선택",
      style: .plain,
      target: self,
      action: #selector(toggleAllPages)
    )
  }

  private func configureLayout() {
    let accountButtons = UIStackView(arrangedSubviews: [connectButton, signOutButton])
    accountButtons.axis = .horizontal
    accountButtons.distribution = .fillEqually
    accountButtons.spacing = 10

    let accountStack = UIStackView(arrangedSubviews: [
      configurationLabel, accountLabel, accountButtons,
    ])
    accountStack.axis = .vertical
    accountStack.spacing = 10
    accountStack.translatesAutoresizingMaskIntoConstraints = false

    let accountCard = UIView()
    accountCard.backgroundColor = .secondarySystemGroupedBackground
    accountCard.layer.cornerRadius = 16
    accountCard.layer.cornerCurve = .continuous
    accountCard.addSubview(accountStack)
    NSLayoutConstraint.activate([
      accountStack.leadingAnchor.constraint(equalTo: accountCard.leadingAnchor, constant: 16),
      accountStack.trailingAnchor.constraint(equalTo: accountCard.trailingAnchor, constant: -16),
      accountStack.topAnchor.constraint(equalTo: accountCard.topAnchor, constant: 16),
      accountStack.bottomAnchor.constraint(equalTo: accountCard.bottomAnchor, constant: -16),
    ])

    let uploadButtons = UIStackView(arrangedSubviews: [pdfButton, docsButton])
    uploadButtons.axis = .vertical
    uploadButtons.distribution = .fillEqually
    uploadButtons.spacing = 10

    let secondaryActions = UIStackView(arrangedSubviews: [retryButton, openResultButton])
    secondaryActions.axis = .horizontal
    secondaryActions.distribution = .fillEqually
    secondaryActions.spacing = 10

    let actionStack = UIStackView(arrangedSubviews: [
      selectionLabel, uploadButtons, progressLabel, progressView, secondaryActions,
    ])
    actionStack.axis = .vertical
    actionStack.spacing = 10

    let rootStack = UIStackView(arrangedSubviews: [accountCard, tableView, actionStack])
    rootStack.axis = .vertical
    rootStack.spacing = 12
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(rootStack)
    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      rootStack.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      rootStack.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
      tableView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
    ])
  }

  private func resolveEnvironmentIfNeeded() {
    guard environment == nil else { return }
    do {
      environment = try UIKitAppEnvironment()
    } catch {
      progressLabel.text = "차단됨: 앱 문서 저장소를 열지 못했습니다. \(error.localizedDescription)"
      progressLabel.textColor = .systemRed
    }
  }

  private func reloadDocuments() {
    guard let environment else {
      documents = []
      tableView.reloadData()
      updateSelectionUI()
      return
    }
    do {
      documents = try environment.fetchFolders()
        .flatMap(\.sortedDocuments)
        .sorted { $0.updatedAt > $1.updatedAt }
      let availablePageIDs = Set(documents.flatMap { $0.pages.map(\.id) })
      selectedPageIDs.formIntersection(availablePageIDs)
      tableView.reloadData()
      tableView.backgroundView =
        documents.isEmpty
        ? emptyStateLabel("업로드할 스캔 문서가 없습니다.\n먼저 라이브러리에서 문서를 스캔하세요.")
        : nil
    } catch {
      documents = []
      tableView.reloadData()
      tableView.backgroundView = emptyStateLabel("문서를 불러오지 못했습니다.\n\(error.localizedDescription)")
    }
    updateSelectionUI()
  }

  private func refreshConfigurationUI() {
    let availability = workspaceService.availability
    configurationLabel.text = availability.userMessage
    configurationLabel.textColor = availability.isReady ? .secondaryLabel : .systemRed
    configurationLabel.accessibilityIdentifier = "google.oauth.configuration"

    if workspaceService.isConnected {
      accountLabel.text = workspaceService.signedInEmail.map { "연결됨: \($0)" } ?? "Google 계정 연결됨"
      accountLabel.textColor = .systemGreen
    } else {
      accountLabel.text =
        availability.isReady
        ? "연결 안 됨 · drive.file 권한만 요청합니다."
        : "Native Google 업로드 미설정"
      accountLabel.textColor = .secondaryLabel
    }
    connectButton.configuration?.title =
      workspaceService.isConnected
      ? "1. 다른 Google 계정 연결"
      : "1. Google 계정 연결"
    signOutButton.isHidden = !workspaceService.isConnected
    updateSelectionUI()
  }

  private func updateSelectionUI() {
    let totalPages = documents.reduce(0) { $0 + $1.pageCount }
    selectionLabel.text = "2. 페이지 선택 · \(selectedPageIDs.count) / \(totalPages)페이지"
    navigationItem.rightBarButtonItem?.title =
      selectedPageIDs.count == totalPages && totalPages > 0
      ? "전체 해제"
      : "전체 선택"
    navigationItem.rightBarButtonItem?.isEnabled = totalPages > 0 && !isBusy

    let canUpload =
      workspaceService.availability.isReady
      && workspaceService.isConnected
      && !selectedPageIDs.isEmpty
      && !isBusy
    pdfButton.isEnabled = canUpload
    docsButton.isEnabled = canUpload
    connectButton.isEnabled = workspaceService.availability.isReady && !isBusy
    signOutButton.isEnabled = !isBusy
  }

  @objc private func connectTapped() {
    setBusy(true)
    progressLabel.text = "Google 계정 연결을 기다리는 중…"
    progressLabel.textColor = .secondaryLabel
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.workspaceService.connect(presenting: self)
        self.progressLabel.text = "Google 계정이 연결되었습니다. 선택한 페이지를 직접 업로드할 수 있습니다."
        self.progressLabel.textColor = .systemGreen
      } catch {
        self.progressLabel.text = error.localizedDescription
        self.progressLabel.textColor = .systemRed
      }
      self.setBusy(false)
      self.refreshConfigurationUI()
    }
  }

  @objc private func signOutTapped() {
    workspaceService.signOut()
    lastAttempt = nil
    retryButton.isHidden = true
    openResultButton.isHidden = true
    progressView.progress = 0
    progressLabel.text = "Google 계정 연결을 해제했습니다."
    progressLabel.textColor = .secondaryLabel
    refreshConfigurationUI()
  }

  @objc private func uploadPDFTapped() {
    prepareUpload(format: .drivePDF)
  }

  @objc private func uploadDocsTapped() {
    prepareUpload(format: .googleDocsOCR)
  }

  @objc private func retryTapped() {
    guard let lastAttempt else { return }
    performUpload(lastAttempt)
  }

  @objc private func openUploadedFileTapped() {
    guard let lastUploadedURL else { return }
    UIApplication.shared.open(lastUploadedURL)
  }

  @objc private func toggleAllPages() {
    let allIDs = Set(documents.flatMap { $0.pages.map(\.id) })
    selectedPageIDs = selectedPageIDs == allIDs ? [] : allIDs
    tableView.reloadData()
    updateSelectionUI()
  }

  private func prepareUpload(format: GoogleWorkspaceUploadFormat) {
    do {
      let selections = try documents.compactMap { document -> ScanExportSelection? in
        let ids = Set(document.pages.map(\.id)).intersection(selectedPageIDs)
        guard !ids.isEmpty else { return nil }
        return try ScanExportSelection(document: document, selectedPageIDs: ids)
      }
      guard !selections.isEmpty else { return }
      let attempt = UploadAttempt(selections: selections, format: format)
      lastAttempt = attempt
      performUpload(attempt)
    } catch {
      progressLabel.text = "선택한 페이지를 준비하지 못했습니다. \(error.localizedDescription)"
      progressLabel.textColor = .systemRed
    }
  }

  private func performUpload(_ attempt: UploadAttempt) {
    guard let environment else { return }
    setBusy(true)
    retryButton.isHidden = true
    openResultButton.isHidden = true
    lastUploadedURL = nil
    progressView.progress = 0
    progressLabel.text = "선택한 페이지를 PDF로 준비하는 중…"
    progressLabel.textColor = .secondaryLabel

    Task { [weak self] in
      guard let self else { return }
      do {
        let files = try await self.workspaceService.upload(
          selections: attempt.selections,
          format: attempt.format,
          imageReader: environment.imageStore,
          presenting: self
        ) { [weak self] progress in
          self?.apply(progress)
        }
        self.lastAttempt = nil
        self.lastUploadedURL = files.compactMap(\.webViewLink).first
        self.openResultButton.isHidden = self.lastUploadedURL == nil
        self.progressView.progress = 1
        self.progressLabel.text = "Google Drive가 \(files.count)개 파일의 업로드 완료를 응답했습니다."
        self.progressLabel.textColor = .systemGreen
      } catch {
        self.retryButton.isHidden = false
        self.progressLabel.text = "업로드 실패: \(error.localizedDescription)"
        self.progressLabel.textColor = .systemRed
      }
      self.setBusy(false)
    }
  }

  private func apply(_ progress: GoogleWorkspaceUploadProgress) {
    progressView.progress = Float(progress.fractionCompleted)
    switch progress.phase {
    case .preparing:
      progressLabel.text = "\(progress.documentTitle) PDF를 만드는 중…"
    case .uploading:
      progressLabel.text =
        "\(progress.documentTitle) 업로드 중 · \(Int(progress.fractionCompleted * 100))%"
    case .completed:
      progressLabel.text = "\(progress.completedDocuments)/\(progress.totalDocuments)개 업로드 완료"
    }
    progressLabel.textColor = .secondaryLabel
  }

  private func setBusy(_ busy: Bool) {
    isBusy = busy
    tableView.isUserInteractionEnabled = !busy
    updateSelectionUI()
  }

  private func emptyStateLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.textAlignment = .center
    label.textColor = .secondaryLabel
    label.font = .preferredFont(forTextStyle: .body)
    label.numberOfLines = 0
    return label
  }

  private func configureButton(
    _ button: UIButton,
    title: String,
    imageName: String,
    style: ButtonStyle,
    action: Selector
  ) {
    var configuration: UIButton.Configuration
    switch style {
    case .filled: configuration = .filled()
    case .tinted: configuration = .tinted()
    case .gray: configuration = .gray()
    }
    configuration.title = title
    configuration.image = UIImage(systemName: imageName)
    configuration.imagePadding = 7
    configuration.cornerStyle = .large
    configuration.buttonSize = .large
    button.configuration = configuration
    button.addTarget(self, action: action, for: .touchUpInside)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
  }

  private enum ButtonStyle {
    case filled
    case tinted
    case gray
  }
}

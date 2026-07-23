import Combine
import UIKit

@MainActor
final class CameraViewController: UIViewController {
  private struct PendingPage {
    let image: CGImage
  }

  private let environment: UIKitAppEnvironment
  private let scanner = DocumentScannerModel()
  private let previewView = ScannerPreviewView()
  private let statusLabel = UILabel()
  private let destinationButton = UIButton(type: .system)
  private let modeControl = UISegmentedControl(items: ["1페이지", "책 2페이지"])
  private let bookControls = UIStackView()
  private let gutterSlider = UISlider()
  private let automaticGutterButton = UIButton(type: .system)
  private let autoButton = UIButton(type: .system)
  private let silentButton = UIButton(type: .system)
  private let timerButton = UIButton(type: .system)
  private let lensControl = UISegmentedControl()
  private let optionsPanel = UIView()
  private let optionsScrollView = UIScrollView()
  private let optionsStack = UIStackView()
  private let shutterDock = UIView()
  private let shutterButton = UIButton(type: .custom)
  private let autoCaptureTrackLayer = CAShapeLayer()
  private let autoCaptureProgressLayer = CAShapeLayer()
  private let pendingLabel = UILabel()
  private var cancellables = Set<AnyCancellable>()
  private var pendingPages: [PendingPage] = []
  private var lastResultID: UUID?
  private var latestBookTimestamp: Date?
  private var latestAutomaticGutterRatio: CGFloat?
  private var isRestoringAutomaticGutter = false
  private var destinationFolder: ScanFolder?
  private var destinationDocument: ScanDocument?
  private var appliedVideoRotationAngle: CGFloat?
  private var displayedLenses: [ScannerCameraLens] = []

  init(environment: UIKitAppEnvironment) {
    self.environment = environment
    super.init(nibName: nil, bundle: nil)
    title = "촬영"
    navigationItem.largeTitleDisplayMode = .never
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    destinationFolder = destinationFolder ?? (try? environment.fetchFolders().first)
    configurePreview()
    configureControls()
    bindScanner()
    applyStoredSettings()
    updateDestinationMenu()
    updatePendingState()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyStoredSettings()
    scanner.start()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateVideoRotationIfNeeded()
    updateAutoCaptureRingPath()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    scanner.stop()
  }

  func setDestination(folder: ScanFolder, document: ScanDocument? = nil) {
    destinationFolder = folder
    destinationDocument = document
    if isViewLoaded {
      updateDestinationMenu()
    }
  }

  private func updateVideoRotationIfNeeded() {
    guard let orientation = view.window?.windowScene?.interfaceOrientation else { return }
    let angle = ScannerPreviewView.preferredVideoRotationAngle(for: orientation)
    guard appliedVideoRotationAngle != angle else { return }
    appliedVideoRotationAngle = angle
    previewView.updateVideoRotationAngle(angle)
    scanner.updateVideoRotationAngle(angle)
  }

  private func configurePreview() {
    previewView.translatesAutoresizingMaskIntoConstraints = false
    previewView.attach(session: scanner.session)
    view.addSubview(previewView)
    NSLayoutConstraint.activate([
      previewView.topAnchor.constraint(equalTo: view.topAnchor),
      previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func configureControls() {
    statusLabel.font = .preferredFont(forTextStyle: .footnote)
    statusLabel.textColor = .white
    statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.64)
    statusLabel.layer.cornerRadius = 15
    statusLabel.clipsToBounds = true
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 1
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.accessibilityTraits.insert(.updatesFrequently)
    statusLabel.accessibilityIdentifier = "scanner.status"

    var destinationConfiguration = UIButton.Configuration.gray()
    destinationConfiguration.image = UIImage(systemName: "folder")
    destinationConfiguration.imagePadding = 7
    destinationConfiguration.cornerStyle = .capsule
    destinationButton.configuration = destinationConfiguration
    destinationButton.showsMenuAsPrimaryAction = true

    modeControl.selectedSegmentIndex = 0
    modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
    configureBookControls()

    configureQuickButton(autoButton, title: "자동 스캔", image: "viewfinder.circle")
    autoButton.addTarget(self, action: #selector(toggleAutoScan), for: .touchUpInside)
    configureQuickButton(silentButton, title: "완전 무음", image: "speaker.slash")
    silentButton.addTarget(self, action: #selector(toggleSilent), for: .touchUpInside)
    configureQuickButton(timerButton, title: "타이머 끔", image: "timer")
    timerButton.accessibilityLabel = "촬영 타이머"
    timerButton.showsMenuAsPrimaryAction = true
    configureTimerMenu()

    lensControl.selectedSegmentTintColor = .systemBlue
    lensControl.accessibilityLabel = "카메라 렌즈"
    lensControl.addTarget(self, action: #selector(lensChanged), for: .valueChanged)
    lensControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    lensControl.isHidden = true

    shutterButton.translatesAutoresizingMaskIntoConstraints = false
    shutterButton.backgroundColor = .white
    shutterButton.layer.cornerRadius = 38
    shutterButton.layer.borderWidth = 0
    shutterButton.accessibilityLabel = "문서 촬영"
    shutterButton.accessibilityIdentifier = "documentShutter"
    shutterButton.accessibilityHint = "현재 보이는 문서를 촬영합니다."
    shutterButton.addTarget(self, action: #selector(capture), for: .touchUpInside)
    configureAutoCaptureRing()

    pendingLabel.font = .preferredFont(forTextStyle: .caption1)
    pendingLabel.textAlignment = .center
    pendingLabel.textColor = .secondaryLabel

    let quickRow = UIStackView(arrangedSubviews: [autoButton, silentButton, timerButton])
    quickRow.axis = .horizontal
    quickRow.distribution = .fillEqually
    quickRow.spacing = 10

    optionsStack.addArrangedSubview(destinationButton)
    optionsStack.addArrangedSubview(modeControl)
    optionsStack.addArrangedSubview(bookControls)
    optionsStack.addArrangedSubview(quickRow)
    optionsStack.addArrangedSubview(lensControl)
    optionsStack.translatesAutoresizingMaskIntoConstraints = false
    optionsStack.axis = .vertical
    optionsStack.alignment = .fill
    optionsStack.spacing = 10
    optionsStack.isLayoutMarginsRelativeArrangement = true
    optionsStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 14,
      leading: 18,
      bottom: 14,
      trailing: 18
    )

    optionsScrollView.translatesAutoresizingMaskIntoConstraints = false
    optionsScrollView.alwaysBounceVertical = true
    optionsScrollView.showsVerticalScrollIndicator = false
    optionsScrollView.contentInsetAdjustmentBehavior = .never
    optionsScrollView.addSubview(optionsStack)

    optionsPanel.translatesAutoresizingMaskIntoConstraints = false
    optionsPanel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
    optionsPanel.layer.cornerRadius = 24
    optionsPanel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    optionsPanel.clipsToBounds = true
    optionsPanel.addSubview(optionsScrollView)

    shutterDock.translatesAutoresizingMaskIntoConstraints = false
    shutterDock.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
    shutterDock.addSubview(shutterButton)
    shutterDock.addSubview(pendingLabel)
    pendingLabel.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(statusLabel)
    view.addSubview(optionsPanel)
    view.addSubview(shutterDock)

    let preferredOptionsHeight = optionsPanel.heightAnchor.constraint(equalToConstant: 256)
    preferredOptionsHeight.priority = .defaultHigh
    NSLayoutConstraint.activate([
      statusLabel.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor,
        constant: 10
      ),
      statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
      statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -44),
      statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

      shutterDock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      shutterDock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      shutterDock.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      shutterDock.heightAnchor.constraint(equalToConstant: 116),

      shutterButton.topAnchor.constraint(equalTo: shutterDock.topAnchor, constant: 8),
      shutterButton.centerXAnchor.constraint(equalTo: shutterDock.centerXAnchor),
      shutterButton.widthAnchor.constraint(equalToConstant: 76),
      shutterButton.heightAnchor.constraint(equalToConstant: 76),

      pendingLabel.topAnchor.constraint(equalTo: shutterButton.bottomAnchor, constant: 3),
      pendingLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: shutterDock.leadingAnchor,
        constant: 18
      ),
      pendingLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: shutterDock.trailingAnchor,
        constant: -18
      ),
      pendingLabel.centerXAnchor.constraint(equalTo: shutterDock.centerXAnchor),
      pendingLabel.bottomAnchor.constraint(
        lessThanOrEqualTo: shutterDock.bottomAnchor,
        constant: -5
      ),

      optionsPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      optionsPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      optionsPanel.bottomAnchor.constraint(equalTo: shutterDock.topAnchor),
      optionsPanel.topAnchor.constraint(
        greaterThanOrEqualTo: statusLabel.bottomAnchor,
        constant: 8
      ),
      preferredOptionsHeight,

      optionsScrollView.topAnchor.constraint(equalTo: optionsPanel.topAnchor),
      optionsScrollView.leadingAnchor.constraint(equalTo: optionsPanel.leadingAnchor),
      optionsScrollView.trailingAnchor.constraint(equalTo: optionsPanel.trailingAnchor),
      optionsScrollView.bottomAnchor.constraint(equalTo: optionsPanel.bottomAnchor),

      optionsStack.topAnchor.constraint(equalTo: optionsScrollView.contentLayoutGuide.topAnchor),
      optionsStack.leadingAnchor.constraint(
        equalTo: optionsScrollView.contentLayoutGuide.leadingAnchor
      ),
      optionsStack.trailingAnchor.constraint(
        equalTo: optionsScrollView.contentLayoutGuide.trailingAnchor
      ),
      optionsStack.bottomAnchor.constraint(
        equalTo: optionsScrollView.contentLayoutGuide.bottomAnchor
      ),
      optionsStack.widthAnchor.constraint(equalTo: optionsScrollView.frameLayoutGuide.widthAnchor),
    ])

    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "저장",
      style: .done,
      target: self,
      action: #selector(savePendingPages)
    )
  }

  private func bindScanner() {
    scanner.$liveDetection
      .receive(on: DispatchQueue.main)
      .sink { [weak self] detection in
        guard let self else { return }
        let gutter =
          self.scanner.captureMode == .bookTwoPage
          ? self.scanner.manualGutterRatio
            ?? self.scanner.liveBookGutterRatio
            ?? 0.5
          : nil
        self.previewView.update(detection: detection, gutterRatio: gutter)
        self.updateAutoCaptureProgress(detection)
      }
      .store(in: &cancellables)

    scanner.$phase
      .receive(on: DispatchQueue.main)
      .sink { [weak self] phase in
        self?.updatePhase(phase)
      }
      .store(in: &cancellables)

    scanner.$analysisDiagnostics
      .receive(on: DispatchQueue.main)
      .sink { [weak self] diagnostics in
        guard let self, case .searching = self.scanner.phase else { return }
        self.statusLabel.text = "문서 찾는 중 · \(diagnostics.statusText)"
      }
      .store(in: &cancellables)

    scanner.$lastResult
      .compactMap { $0 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] result in
        self?.integrate(result)
      }
      .store(in: &cancellables)

    scanner.$lastError
      .compactMap { $0 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] error in
        self?.presentError(error, title: "스캔하지 못했어요")
      }
      .store(in: &cancellables)

    Publishers.CombineLatest(
      scanner.$cameraCapabilities,
      scanner.$activeCameraLens
    )
    .receive(on: DispatchQueue.main)
    .sink { [weak self] capabilities, activeLens in
      self?.updateLensControl(
        capabilities: capabilities,
        activeLens: activeLens
      )
    }
    .store(in: &cancellables)
  }

  private func configureQuickButton(_ button: UIButton, title: String, image: String) {
    var configuration = UIButton.Configuration.tinted()
    configuration.title = title
    configuration.image = UIImage(systemName: image)
    configuration.imagePadding = 6
    configuration.cornerStyle = .medium
    button.configuration = configuration
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
  }

  private func configureAutoCaptureRing() {
    for layer in [autoCaptureTrackLayer, autoCaptureProgressLayer] {
      layer.fillColor = UIColor.clear.cgColor
      layer.lineWidth = 6
      shutterButton.layer.addSublayer(layer)
    }
    autoCaptureTrackLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.22).cgColor
    autoCaptureTrackLayer.strokeEnd = 1
    autoCaptureProgressLayer.strokeColor = UIColor.systemBlue.cgColor
    autoCaptureProgressLayer.lineCap = .round
    autoCaptureProgressLayer.strokeEnd = 0
    shutterButton.accessibilityValue = "자동 촬영 0%"
  }

  private func updateAutoCaptureRingPath() {
    let bounds = shutterButton.bounds
    guard !bounds.isEmpty else { return }
    let radius = max(0, min(bounds.width, bounds.height) / 2 - 4)
    let path = UIBezierPath(
      arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
      radius: radius,
      startAngle: -.pi / 2,
      endAngle: .pi * 1.5,
      clockwise: true
    ).cgPath
    autoCaptureTrackLayer.frame = bounds
    autoCaptureProgressLayer.frame = bounds
    autoCaptureTrackLayer.path = path
    autoCaptureProgressLayer.path = path
  }

  private func updateAutoCaptureProgress(
    _ detection: LiveRectangleDetection?,
    animated: Bool = true
  ) {
    let autoEnabled = scanner.autoCaptureEnabled
    let progress = autoEnabled ? detection?.stabilityProgress ?? 0 : 0
    let clampedProgress = min(max(progress, 0), 1)
    let color: UIColor
    if detection?.requiresRepositioning == true {
      color = .systemOrange
    } else if detection?.isStable == true {
      color = .systemGreen
    } else if autoEnabled {
      color = .systemBlue
    } else {
      color = .systemGray3
    }

    CATransaction.begin()
    CATransaction.setAnimationDuration(animated ? 0.12 : 0)
    CATransaction.setAnimationTimingFunction(
      CAMediaTimingFunction(name: .easeOut)
    )
    autoCaptureProgressLayer.strokeColor = color.cgColor
    autoCaptureProgressLayer.strokeEnd = clampedProgress
    autoCaptureTrackLayer.strokeColor =
      color.withAlphaComponent(autoEnabled ? 0.22 : 0.35).cgColor
    CATransaction.commit()

    shutterButton.accessibilityValue =
      if detection?.requiresRepositioning == true {
        "문서 전체가 보이도록 카메라를 이동하세요"
      } else if autoEnabled {
        "자동 촬영 \(Int(clampedProgress * 100))%"
      } else {
        "자동 촬영 꺼짐"
      }
  }

  private func configureBookControls() {
    let label = UILabel()
    label.text = "중앙 책등"
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabel

    automaticGutterButton.setTitle("자동", for: .normal)
    automaticGutterButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
    automaticGutterButton.addTarget(
      self,
      action: #selector(useAutomaticGutter),
      for: .touchUpInside
    )

    let heading = UIStackView(arrangedSubviews: [label, UIView(), automaticGutterButton])
    heading.axis = .horizontal
    heading.alignment = .center

    gutterSlider.minimumValue = 0.25
    gutterSlider.maximumValue = 0.75
    gutterSlider.value = 0.5
    gutterSlider.addTarget(self, action: #selector(gutterChanged), for: .valueChanged)
    for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
      gutterSlider.addTarget(self, action: #selector(finishGutterAdjustment), for: event)
    }

    bookControls.axis = .vertical
    bookControls.spacing = 2
    bookControls.addArrangedSubview(heading)
    bookControls.addArrangedSubview(gutterSlider)
    bookControls.isHidden = true
  }

  private func applyStoredSettings() {
    let defaults = UserDefaults.standard
    let storedQuality = defaults.object(forKey: "capture.quality") as? String
    let legacySilentPreference = defaults.object(forKey: "capture.silent") as? Bool
    scanner.autoCaptureEnabled = defaults.object(forKey: "capture.auto") as? Bool ?? true
    if let rawQuality = storedQuality,
       let quality = ScannerCaptureQuality(rawValue: rawQuality)
    {
      scanner.captureQuality = quality
    } else {
      scanner.silentCapturePreferred = legacySilentPreference ?? true
    }
    scanner.captureTimer =
      ScannerCaptureTimer(rawValue: defaults.integer(forKey: "capture.timer")) ?? .off
    let lens =
      ScannerCameraLens(
        rawValue: defaults.string(forKey: "capture.lens") ?? ""
      ) ?? .standard
    scanner.selectCameraLens(lens)
    updateQuickButtons()
  }

  private func updateQuickButtons() {
    autoButton.configuration?.image = UIImage(
      systemName: scanner.autoCaptureEnabled ? "viewfinder.circle.fill" : "viewfinder.circle"
    )
    autoButton.configuration?.baseForegroundColor =
      scanner.autoCaptureEnabled ? .systemBlue : .secondaryLabel
    let isSilent = scanner.captureQuality == .silentVideoFrame
    silentButton.configuration?.image = UIImage(
      systemName: isSilent ? "speaker.slash.fill" : "camera.fill"
    )
    silentButton.configuration?.title = scanner.captureQuality.shortTitle
    silentButton.configuration?.baseForegroundColor =
      isSilent ? .systemBlue : .secondaryLabel
    timerButton.configuration?.title =
      scanner.captureTimer == .off ? "타이머 끔" : scanner.captureTimer.title
    timerButton.configuration?.image = UIImage(
      systemName: scanner.captureTimer == .off ? "timer" : "timer.circle.fill"
    )
    timerButton.configuration?.baseForegroundColor =
      scanner.captureTimer == .off ? .secondaryLabel : .systemBlue
    configureTimerMenu()
    updateAutoCaptureProgress(scanner.liveDetection, animated: false)
  }

  private func configureTimerMenu() {
    timerButton.menu = UIMenu(
      title: "촬영 타이머",
      children: ScannerCaptureTimer.allCases.map { [weak self] timer in
        UIAction(
          title: timer.title,
          state: self?.scanner.captureTimer == timer ? .on : .off
        ) { [weak self] _ in
          guard let self else { return }
          self.scanner.captureTimer = timer
          UserDefaults.standard.set(timer.rawValue, forKey: "capture.timer")
          self.updateQuickButtons()
        }
      }
    )
  }

  private func updateLensControl(
    capabilities: ScannerCameraCapabilities,
    activeLens: ScannerCameraLens
  ) {
    displayedLenses = capabilities.availableLenses
    lensControl.removeAllSegments()
    for (index, lens) in displayedLenses.enumerated() {
      lensControl.insertSegment(withTitle: lens.title, at: index, animated: false)
    }
    lensControl.isHidden = displayedLenses.count <= 1
    lensControl.selectedSegmentIndex =
      displayedLenses.firstIndex(of: activeLens) ?? UISegmentedControl.noSegment
  }

  private func updateDestinationMenu() {
    let title: String
    if let destinationDocument {
      title = "\(destinationDocument.title)에 추가"
    } else {
      title = destinationFolder?.name ?? "저장 폴더 선택"
    }
    destinationButton.configuration?.title = title

    let folders = (try? environment.fetchFolders()) ?? []
    destinationButton.menu = UIMenu(
      title: "저장할 폴더",
      children: folders.map { folder in
        UIAction(
          title: folder.name,
          image: UIImage(systemName: "folder"),
          state: folder.id == destinationFolder?.id && destinationDocument == nil ? .on : .off
        ) { [weak self] _ in
          self?.setDestination(folder: folder)
        }
      }
    )
  }

  private func updatePhase(_ phase: ScannerPhase) {
    switch phase {
    case .idle:
      statusLabel.text = "카메라 준비"
    case .configuring:
      statusLabel.text = "카메라 여는 중"
    case .searching:
      statusLabel.text = "문서 찾는 중 · \(scanner.analysisDiagnostics.statusText)"
    case .stabilizing(let progress):
      if scanner.liveDetection?.requiresRepositioning == true {
        statusLabel.text = "문서 전체가 보이게 이동해 주세요"
      } else {
        statusLabel.text = "고정해 주세요 · \(Int(progress * 100))%"
      }
    case .ready:
      statusLabel.text = scanner.autoCaptureEnabled ? "자동 촬영 준비됨" : "촬영 준비됨"
    case .countdown(let remainingSeconds):
      statusLabel.text = "\(remainingSeconds)초 후 촬영"
    case .capturing:
      statusLabel.text = "촬영 중…"
    case .processing:
      statusLabel.text = "원근을 보정하는 중…"
    case .completed:
      statusLabel.text = "페이지를 추가했어요"
    case .failed(let message):
      statusLabel.text = message
    }
    switch phase {
    case .countdown, .capturing, .processing:
      shutterButton.isEnabled = false
      lensControl.isEnabled = false
    default:
      shutterButton.isEnabled = true
      lensControl.isEnabled = true
    }
  }

  private func integrate(_ result: ScannerCaptureResult) {
    guard result.id != lastResultID else { return }
    lastResultID = result.id
    let newPages = result.pages.map { PendingPage(image: $0.image) }

    if result.mode == .bookTwoPage,
      latestBookTimestamp == result.capturedAt,
      pendingPages.count >= 2
    {
      pendingPages.removeLast(2)
      pendingPages.append(contentsOf: newPages)
    } else {
      pendingPages.append(contentsOf: newPages)
    }

    if result.mode == .bookTwoPage {
      latestBookTimestamp = result.capturedAt
      if result.usedAutomaticGutter {
        latestAutomaticGutterRatio = result.gutterRatio
        if let ratio = result.gutterRatio {
          gutterSlider.value = Float(ratio)
        }
      }
      if isRestoringAutomaticGutter {
        scanner.manualGutterRatio = nil
        isRestoringAutomaticGutter = false
      }
    } else {
      latestBookTimestamp = nil
      latestAutomaticGutterRatio = nil
    }
    updatePendingState()
    updateAutoCaptureProgress(nil, animated: false)
    scanner.prepareForNextCapture()
  }

  private func updatePendingState() {
    pendingLabel.text =
      pendingPages.isEmpty
      ? "촬영한 페이지가 여기에 모입니다."
      : "\(pendingPages.count)페이지 촬영됨"
    navigationItem.rightBarButtonItem?.isEnabled = !pendingPages.isEmpty
  }

  @objc private func modeChanged() {
    scanner.captureMode = modeControl.selectedSegmentIndex == 1 ? .bookTwoPage : .singlePage
    bookControls.isHidden = scanner.captureMode != .bookTwoPage
    previewView.update(
      detection: scanner.liveDetection,
      gutterRatio:
        scanner.captureMode == .bookTwoPage
        ? scanner.manualGutterRatio ?? scanner.liveBookGutterRatio ?? 0.5
        : nil
    )
  }

  @objc private func gutterChanged() {
    scanner.manualGutterRatio = CGFloat(gutterSlider.value)
    previewView.update(
      detection: scanner.liveDetection,
      gutterRatio: CGFloat(gutterSlider.value)
    )
  }

  @objc private func finishGutterAdjustment() {
    guard latestBookTimestamp != nil else { return }
    isRestoringAutomaticGutter = false
    scanner.resplitLastBook(at: CGFloat(gutterSlider.value))
  }

  @objc private func useAutomaticGutter() {
    scanner.manualGutterRatio = nil
    guard latestBookTimestamp != nil, let ratio = latestAutomaticGutterRatio else {
      gutterSlider.value = 0.5
      previewView.update(detection: scanner.liveDetection, gutterRatio: 0.5)
      return
    }
    gutterSlider.value = Float(ratio)
    isRestoringAutomaticGutter = true
    scanner.resplitLastBook(at: ratio)
  }

  @objc private func toggleAutoScan() {
    scanner.autoCaptureEnabled.toggle()
    UserDefaults.standard.set(scanner.autoCaptureEnabled, forKey: "capture.auto")
    updateQuickButtons()
  }

  @objc private func toggleSilent() {
    scanner.captureQuality =
      scanner.captureQuality == .silentVideoFrame
      ? .highQualityPhoto
      : .silentVideoFrame
    UserDefaults.standard.set(
      scanner.captureQuality.rawValue,
      forKey: "capture.quality"
    )
    UserDefaults.standard.set(
      scanner.captureQuality == .silentVideoFrame,
      forKey: "capture.silent"
    )
    updateQuickButtons()
  }

  @objc private func lensChanged() {
    guard displayedLenses.indices.contains(lensControl.selectedSegmentIndex) else {
      return
    }
    let lens = displayedLenses[lensControl.selectedSegmentIndex]
    UserDefaults.standard.set(lens.rawValue, forKey: "capture.lens")
    scanner.selectCameraLens(lens)
  }

  @objc private func capture() {
    scanner.capture()
  }

  @objc private func savePendingPages() {
    guard !pendingPages.isEmpty, let folder = destinationFolder else { return }
    let folderID = folder.id
    let pages = pendingPages
    let enhancer = environment.enhancer
    let rawPreset = UserDefaults.standard.string(forKey: "capture.defaultCorrection")
    let preset = ScanCorrectionPreset(rawValue: rawPreset ?? "") ?? .document
    navigationItem.rightBarButtonItem?.isEnabled = false
    statusLabel.text = "\(pages.count)페이지를 저장하는 중…"

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        let encoded = try pages.map { page in
          let original = try enhancer.jpegData(
            for: page.image,
            preset: .original,
            compressionQuality: 0.96
          )
          let enhanced: Data?
          if preset == .original {
            enhanced = nil
          } else {
            enhanced = try enhancer.jpegData(
              for: page.image,
              preset: preset,
              compressionQuality: 0.94
            )
          }
          return EncodedPage(original: original, enhanced: enhanced)
        }
        DispatchQueue.main.async {
          self?.persist(encoded, folderID: folderID)
        }
      } catch {
        DispatchQueue.main.async {
          guard let self else { return }
          self.updatePendingState()
          self.presentError(error, title: "페이지를 보정하지 못했어요")
        }
      }
    }
  }

  private struct EncodedPage {
    let original: Data
    let enhanced: Data?
  }

  private func persist(_ encodedPages: [EncodedPage], folderID: UUID) {
    guard let folder = (try? environment.fetchFolders())?.first(where: { $0.id == folderID }) else {
      updatePendingState()
      presentMessage(
        title: "저장 폴더를 찾지 못했어요",
        message: "폴더가 삭제되었을 수 있습니다. 저장할 폴더를 다시 선택하세요."
      )
      return
    }
    persist(encodedPages, in: folder)
  }

  private func persist(_ encodedPages: [EncodedPage], in folder: ScanFolder) {
    var createdDocument: ScanDocument?
    var createdPages: [ScanPage] = []
    do {
      let document: ScanDocument
      if let destinationDocument {
        document = destinationDocument
      } else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy. M. d. HH:mm 스캔"
        document = try environment.repository.createDocument(
          title: formatter.string(from: .now),
          in: folder
        )
        createdDocument = document
      }

      for encoded in encodedPages {
        let page = try environment.repository.addPage(
          to: document,
          originalImageData: encoded.original,
          originalFileExtension: "jpg"
        )
        createdPages.append(page)
        if let enhanced = encoded.enhanced {
          try environment.repository.updateEnhancedImage(for: page, data: enhanced)
        }
      }
      pendingPages.removeAll()
      latestBookTimestamp = nil
      latestAutomaticGutterRatio = nil
      destinationDocument = nil
      updatePendingState()
      updateDestinationMenu()
      statusLabel.text = "\(encodedPages.count)페이지를 저장했어요"
    } catch {
      if let createdDocument {
        try? environment.repository.deleteDocument(createdDocument)
      } else {
        for page in createdPages.reversed() {
          try? environment.repository.deletePage(page)
        }
      }
      updatePendingState()
      presentError(error, title: "스캔을 저장하지 못했어요")
    }
  }
}

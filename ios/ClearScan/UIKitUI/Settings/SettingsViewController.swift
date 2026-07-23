import UIKit

@MainActor
final class SettingsViewController: UITableViewController {
  private enum SettingRow {
    static let automaticCapture = 100
  }

  private enum CaptureRow {
    case automaticCapture
    case quality
    case timer
    case lens
  }

  private let defaults: UserDefaults
  private let availableLenses: [ScannerCameraLens]
  private var captureRows: [CaptureRow] {
    var rows: [CaptureRow] = [.automaticCapture, .quality, .timer]
    if availableLenses.count > 1 {
      rows.append(.lens)
    }
    return rows
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    availableLenses = DocumentScannerModel.discoverAvailableCameraLenses()
    super.init(style: .insetGrouped)
    title = "설정"
    navigationItem.largeTitleDisplayMode = .always
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let storedQuality = defaults.object(forKey: "capture.quality") as? String
    let legacySilentPreference = defaults.object(forKey: "capture.silent") as? Bool
    defaults.register(defaults: [
      "capture.auto": true,
      "capture.silent": true,
      "capture.quality": ScannerCaptureQuality.silentVideoFrame.rawValue,
      "capture.timer": ScannerCaptureTimer.off.rawValue,
      "capture.lens": ScannerCameraLens.standard.rawValue,
      "capture.defaultCorrection": ScanCorrectionPreset.document.rawValue,
    ])
    if storedQuality == nil, let legacySilentPreference {
      let migratedQuality: ScannerCaptureQuality =
        legacySilentPreference ? .silentVideoFrame : .highQualityPhoto
      defaults.set(migratedQuality.rawValue, forKey: "capture.quality")
    }
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 3 }

  override func tableView(
    _ tableView: UITableView,
    numberOfRowsInSection section: Int
  ) -> Int {
    switch section {
    case 0: captureRows.count
    case 1: 1
    default: 2
    }
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  ) -> String? {
    switch section {
    case 0: "촬영"
    case 1: "기본 보정"
    default: "기기 내 AI"
    }
  }

  override func tableView(
    _ tableView: UITableView,
    titleForFooterInSection section: Int
  ) -> String? {
    if section == 0 {
      return "완전 무음은 최신 영상 프레임을 사용해 소리가 없지만 해상도·명암 범위가 낮을 수 있습니다. 고화질 사진은 최대 사진 크기를 사용하며 iOS 셔터음이 날 수 있습니다. 0.5×는 초광각 카메라가 있는 기기에서만 표시됩니다."
    }
    if section == 2 {
      return "OCR과 문서 보정은 사진과 텍스트를 외부 서버에 전송하지 않고 기기에서 처리합니다."
    }
    return nil
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
    var configuration = UIListContentConfiguration.valueCell()

    if indexPath.section == 0 {
      switch captureRows[indexPath.row] {
      case .automaticCapture:
        configuration.text = "자동 스캔"
        configuration.image = UIImage(systemName: "viewfinder.circle")
        cell.accessoryView = switchControl(
          tag: SettingRow.automaticCapture,
          isOn: defaults.bool(forKey: "capture.auto")
        )
      case .quality:
        let quality =
          ScannerCaptureQuality(
            rawValue: defaults.string(forKey: "capture.quality") ?? ""
          ) ?? .silentVideoFrame
        configuration.text = "촬영 품질"
        configuration.secondaryText = quality.title
        configuration.image = UIImage(
          systemName: quality == .silentVideoFrame ? "speaker.slash" : "camera"
        )
        cell.accessoryType = .disclosureIndicator
      case .timer:
        let timer =
          ScannerCaptureTimer(
            rawValue: defaults.integer(forKey: "capture.timer")
          ) ?? .off
        configuration.text = "촬영 타이머"
        configuration.secondaryText = timer.title
        configuration.image = UIImage(systemName: "timer")
        cell.accessoryType = .disclosureIndicator
      case .lens:
        let requestedLens =
          ScannerCameraLens(
            rawValue: defaults.string(forKey: "capture.lens") ?? ""
          ) ?? .standard
        let lens = availableLenses.contains(requestedLens) ? requestedLens : .standard
        configuration.text = "카메라 렌즈"
        configuration.secondaryText = lens.title
        configuration.image = UIImage(systemName: "camera.aperture")
        cell.accessoryType = .disclosureIndicator
      }
    } else if indexPath.section == 1 {
      let preset =
        ScanCorrectionPreset(
          rawValue: defaults.string(forKey: "capture.defaultCorrection") ?? ""
        ) ?? .document
      configuration.text = "촬영 후 적용"
      configuration.secondaryText = preset.title
      configuration.image = UIImage(systemName: "slider.horizontal.3")
      cell.accessoryType = .disclosureIndicator
    } else {
      if indexPath.row == 0 {
        configuration.text = "AI OCR"
        configuration.secondaryText = "한국어·영어"
        configuration.image = UIImage(systemName: "text.viewfinder")
      } else {
        configuration.text = "처리 위치"
        configuration.secondaryText = "이 기기"
        configuration.image = UIImage(systemName: "iphone.gen3")
      }
      cell.selectionStyle = .none
    }
    configuration.imageProperties.tintColor = .systemBlue
    cell.contentConfiguration = configuration
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 0 {
      switch captureRows[indexPath.row] {
      case .automaticCapture:
        return
      case .quality:
        presentQualityPicker(from: indexPath)
      case .timer:
        presentTimerPicker(from: indexPath)
      case .lens:
        presentLensPicker(from: indexPath)
      }
      return
    }
    guard indexPath.section == 1 else { return }

    let sheet = UIAlertController(title: "기본 보정", message: nil, preferredStyle: .actionSheet)
    for preset in ScanCorrectionPreset.allCases {
      sheet.addAction(
        UIAlertAction(title: preset.title, style: .default) { [weak self] _ in
          self?.defaults.set(preset.rawValue, forKey: "capture.defaultCorrection")
          self?.tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
        })
    }
    sheet.addAction(UIAlertAction(title: "취소", style: .cancel))
    sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
    sheet.popoverPresentationController?.sourceRect =
      tableView.cellForRow(at: indexPath)?.bounds ?? .zero
    present(sheet, animated: true)
  }

  private func presentQualityPicker(from indexPath: IndexPath) {
    let sheet = UIAlertController(
      title: "촬영 품질",
      message: "완전 무음은 영상 프레임, 고화질 사진은 최대 지원 사진 크기를 사용합니다.",
      preferredStyle: .actionSheet
    )
    for quality in ScannerCaptureQuality.allCases {
      sheet.addAction(
        UIAlertAction(
          title: quality.title,
          style: .default
        ) { [weak self] _ in
          guard let self else { return }
          self.defaults.set(quality.rawValue, forKey: "capture.quality")
          self.defaults.set(
            quality == .silentVideoFrame,
            forKey: "capture.silent"
          )
          self.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
        }
      )
    }
    presentSheet(sheet, from: indexPath)
  }

  private func presentTimerPicker(from indexPath: IndexPath) {
    let sheet = UIAlertController(
      title: "촬영 타이머",
      message: nil,
      preferredStyle: .actionSheet
    )
    for timer in ScannerCaptureTimer.allCases {
      sheet.addAction(
        UIAlertAction(title: timer.title, style: .default) { [weak self] _ in
          self?.defaults.set(timer.rawValue, forKey: "capture.timer")
          self?.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
        }
      )
    }
    presentSheet(sheet, from: indexPath)
  }

  private func presentLensPicker(from indexPath: IndexPath) {
    let sheet = UIAlertController(
      title: "카메라 렌즈",
      message: "사용 가능한 물리 카메라만 표시됩니다.",
      preferredStyle: .actionSheet
    )
    for lens in availableLenses {
      sheet.addAction(
        UIAlertAction(title: lens.title, style: .default) { [weak self] _ in
          self?.defaults.set(lens.rawValue, forKey: "capture.lens")
          self?.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
        }
      )
    }
    presentSheet(sheet, from: indexPath)
  }

  private func presentSheet(_ sheet: UIAlertController, from indexPath: IndexPath) {
    sheet.addAction(UIAlertAction(title: "취소", style: .cancel))
    sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
    sheet.popoverPresentationController?.sourceRect =
      tableView.cellForRow(at: indexPath)?.bounds ?? .zero
    present(sheet, animated: true)
  }

  private func switchControl(tag: Int, isOn: Bool) -> UISwitch {
    let control = UISwitch()
    control.tag = tag
    control.isOn = isOn
    control.addTarget(self, action: #selector(settingSwitchChanged(_:)), for: .valueChanged)
    return control
  }

  @objc private func settingSwitchChanged(_ sender: UISwitch) {
    switch sender.tag {
    case SettingRow.automaticCapture:
      defaults.set(sender.isOn, forKey: "capture.auto")
    default:
      break
    }
  }
}

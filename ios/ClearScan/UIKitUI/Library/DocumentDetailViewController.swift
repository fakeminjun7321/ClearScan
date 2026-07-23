import UIKit

@MainActor
final class DocumentDetailViewController: UITableViewController {
  var onAddPages: ((ScanDocument) -> Void)?

  private let environment: UIKitAppEnvironment
  private let document: ScanDocument
  private var pages: [ScanPage] = []
  private lazy var selectionLabel = UILabel()

  init(environment: UIKitAppEnvironment, document: ScanDocument) {
    self.environment = environment
    self.document = document
    super.init(style: .plain)
    title = document.title
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.register(
      ThumbnailSubtitleCell.self,
      forCellReuseIdentifier: ThumbnailSubtitleCell.reuseIdentifier
    )
    tableView.rowHeight = 90
    tableView.allowsMultipleSelectionDuringEditing = true
    editButtonItem.accessibilityIdentifier = "editPages"
    navigationItem.rightBarButtonItems = [
      editButtonItem,
      UIBarButtonItem(
        image: UIImage(systemName: "plus"),
        style: .plain,
        target: self,
        action: #selector(addPages)
      ),
      UIBarButtonItem(
        image: UIImage(systemName: "pencil"),
        style: .plain,
        target: self,
        action: #selector(renameDocument)
      ),
    ]
    configureSelectionToolbar()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadPages()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    guard isMovingFromParent || navigationController?.isBeingDismissed == true else { return }
    navigationController?.setToolbarHidden(true, animated: false)
    tabBarController?.tabBar.isHidden = false
  }

  override func tableView(
    _ tableView: UITableView,
    numberOfRowsInSection section: Int
  ) -> Int {
    pages.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    guard
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ThumbnailSubtitleCell.reuseIdentifier,
        for: indexPath
      ) as? ThumbnailSubtitleCell
    else { return UITableViewCell() }

    let page = pages[indexPath.row]
    cell.accessibilityIdentifier = "page.\(indexPath.row + 1)"
    cell.titleLabel.text = "\(indexPath.row + 1)페이지"
    cell.subtitleLabel.text = page.enhancedImagePath == nil ? "원본" : "보정본"
    cell.badgeLabel.text = page.recognizedText == nil ? nil : "AI OCR 완료"
    cell.storedImageView.load(path: page.preferredImagePath, from: environment.imageStore)
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if tableView.isEditing {
      updateSelectionToolbar()
      return
    }
    tableView.deselectRow(at: indexPath, animated: true)
    let editor = PageEditorViewController(
      environment: environment,
      page: pages[indexPath.row]
    )
    editor.onPageDeleted = { [weak self] in
      self?.navigationController?.popViewController(animated: true)
    }
    navigationController?.pushViewController(editor, animated: true)
  }

  override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
    guard tableView.isEditing else { return }
    updateSelectionToolbar()
  }

  override func setEditing(_ editing: Bool, animated: Bool) {
    super.setEditing(editing, animated: animated)
    tableView.setEditing(editing, animated: animated)
    // A navigation toolbar and a tab bar compete for the same bottom safe-area.
    // Hide the tab bar while selecting pages so the export action remains visible
    // and tappable on both iPhone and iPad.
    tabBarController?.tabBar.isHidden = editing
    navigationController?.setToolbarHidden(!editing, animated: animated)
    if !editing {
      for indexPath in tableView.indexPathsForSelectedRows ?? [] {
        tableView.deselectRow(at: indexPath, animated: false)
      }
    }
    updateSelectionToolbar()
  }

  override func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    let page = pages[indexPath.row]
    let delete = UIContextualAction(style: .destructive, title: "삭제") { [weak self] _, _, finish in
      guard let self else { return finish(false) }
      do {
        try self.environment.repository.deletePage(page)
        self.reloadPages()
        finish(true)
      } catch {
        self.presentError(error, title: "페이지를 삭제하지 못했어요")
        finish(false)
      }
    }
    return UISwipeActionsConfiguration(actions: [delete])
  }

  @objc private func addPages() {
    onAddPages?(document)
  }

  @objc private func showExportFormats(_ sender: UIBarButtonItem) {
    guard !selectedPages.isEmpty else { return }
    let sheet = UIAlertController(
      title: "선택한 \(selectedPages.count)페이지 내보내기",
      message: nil,
      preferredStyle: .actionSheet
    )
    for format in ScanExportFormat.allCases {
      sheet.addAction(
        UIAlertAction(title: format.rawValue.uppercased(), style: .default) {
          [weak self] _ in
          self?.exportSelectedPages(as: format, sender: sender)
        })
    }
    sheet.addAction(UIAlertAction(title: "취소", style: .cancel))
    sheet.popoverPresentationController?.barButtonItem = sender
    present(sheet, animated: true)
  }

  @objc private func renameDocument() {
    let alert = UIAlertController(title: "문서 이름 변경", message: nil, preferredStyle: .alert)
    alert.addTextField { [document] field in
      field.text = document.title
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "취소", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "저장", style: .default) { [weak self, weak alert] _ in
        guard let self else { return }
        do {
          try self.environment.repository.renameDocument(
            self.document,
            title: alert?.textFields?.first?.text ?? ""
          )
          self.title = self.document.title
        } catch {
          self.presentError(error, title: "이름을 바꾸지 못했어요")
        }
      })
    present(alert, animated: true)
  }

  private func reloadPages() {
    pages = document.sortedPages
    tableView.reloadData()
    updateSelectionToolbar()
  }

  private var selectedPages: [ScanPage] {
    (tableView.indexPathsForSelectedRows ?? [])
      .map(\.row)
      .filter { pages.indices.contains($0) }
      .sorted()
      .map { pages[$0] }
  }

  private func configureSelectionToolbar() {
    selectionLabel.font = .preferredFont(forTextStyle: .subheadline)
    selectionLabel.textColor = .secondaryLabel

    let exportItem = UIBarButtonItem(
      title: "내보내기",
      style: .done,
      target: self,
      action: #selector(showExportFormats(_:))
    )
    exportItem.accessibilityIdentifier = "exportSelectedPages"
    toolbarItems = [
      UIBarButtonItem(customView: selectionLabel),
      UIBarButtonItem(
        barButtonSystemItem: .flexibleSpace,
        target: nil,
        action: nil
      ),
      exportItem,
    ]
    navigationController?.setToolbarHidden(true, animated: false)
  }

  private func updateSelectionToolbar() {
    let count = selectedPages.count
    selectionLabel.text = "\(count)페이지 선택"
    toolbarItems?.last?.isEnabled = count > 0
  }

  private func exportSelectedPages(as format: ScanExportFormat, sender: UIBarButtonItem) {
    let selectedIDs = Set(selectedPages.map(\.id))
    do {
      let selection = try ScanExportSelection(
        document: document,
        selectedPageIDs: selectedIDs
      )
      let exporter = try ScanExportService(imageReader: environment.imageStore)
      sender.isEnabled = false
      selectionLabel.text = "내보내는 중…"

      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        do {
          let result = try exporter.export(selection, as: format)
          DispatchQueue.main.async {
            guard let self else { return }
            sender.isEnabled = true
            self.updateSelectionToolbar()
            let activity = UIActivityViewController(
              activityItems: result.fileURLs,
              applicationActivities: nil
            )
            activity.popoverPresentationController?.barButtonItem = sender
            activity.completionWithItemsHandler = { _, _, _, _ in
              try? exporter.deleteExport(result)
            }
            self.present(activity, animated: true)
          }
        } catch {
          DispatchQueue.main.async {
            guard let self else { return }
            sender.isEnabled = true
            self.updateSelectionToolbar()
            self.presentError(error, title: "내보내지 못했어요")
          }
        }
      }
    } catch {
      presentError(error, title: "내보낼 페이지를 준비하지 못했어요")
    }
  }
}

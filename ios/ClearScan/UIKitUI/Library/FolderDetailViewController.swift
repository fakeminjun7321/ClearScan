import UIKit

@MainActor
final class FolderDetailViewController: UITableViewController, UISearchResultsUpdating {
  var onScan: ((ScanFolder, ScanDocument?) -> Void)?

  private let environment: UIKitAppEnvironment
  private let folder: ScanFolder
  private var documents: [ScanDocument] = []
  private var filteredDocuments: [ScanDocument] = []
  private let searchController = UISearchController(searchResultsController: nil)

  init(environment: UIKitAppEnvironment, folder: ScanFolder) {
    self.environment = environment
    self.folder = folder
    super.init(style: .plain)
    title = folder.name
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
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "camera.viewfinder"),
      style: .plain,
      target: self,
      action: #selector(scanDocument)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = "이 폴더에 스캔"

    searchController.searchResultsUpdater = self
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.searchBar.placeholder = "문서 이름 또는 OCR 내용 검색"
    searchController.searchBar.accessibilityIdentifier = "folderDocumentSearch"
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = false
    definesPresentationContext = true
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadDocuments()
  }

  override func tableView(
    _ tableView: UITableView,
    numberOfRowsInSection section: Int
  ) -> Int {
    filteredDocuments.count
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

    let document = filteredDocuments[indexPath.row]
    cell.accessibilityIdentifier = "document.\(document.title)"
    cell.titleLabel.text = document.title
    cell.subtitleLabel.text =
      "\(document.pageCount)페이지 · \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))"
    cell.badgeLabel.text =
      document.pages.contains { $0.recognizedText != nil }
      ? "AI OCR 텍스트 포함"
      : nil
    cell.storedImageView.load(
      path: document.sortedPages.first?.preferredImagePath,
      from: environment.imageStore
    )
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let detail = DocumentDetailViewController(
      environment: environment,
      document: filteredDocuments[indexPath.row]
    )
    detail.onAddPages = { [weak self] document in
      guard let self else { return }
      self.onScan?(self.folder, document)
    }
    navigationController?.pushViewController(detail, animated: true)
  }

  override func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    let document = filteredDocuments[indexPath.row]
    let delete = UIContextualAction(style: .destructive, title: "삭제") { [weak self] _, _, finish in
      guard let self else { return finish(false) }
      do {
        try self.environment.repository.deleteDocument(document)
        self.reloadDocuments()
        finish(true)
      } catch {
        self.presentError(error, title: "문서를 삭제하지 못했어요")
        finish(false)
      }
    }
    return UISwipeActionsConfiguration(actions: [delete])
  }

  @objc private func scanDocument() {
    onScan?(folder, nil)
  }

  func updateSearchResults(for searchController: UISearchController) {
    applySearch(searchController.searchBar.text)
  }

  private func reloadDocuments() {
    documents = folder.sortedDocuments
    applySearch(searchController.searchBar.text, reloadTable: false)
    tableView.reloadData()

    updateEmptyState()
  }

  private func applySearch(_ candidate: String?, reloadTable: Bool = true) {
    let query =
      candidate?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ?? ""
    if query.isEmpty {
      filteredDocuments = documents
    } else {
      filteredDocuments = documents.filter { document in
        let searchableText = ([document.title] + document.pages.compactMap(\.recognizedText))
          .joined(separator: "\n")
          .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return searchableText.localizedStandardContains(query)
      }
    }
    if reloadTable {
      tableView.reloadData()
      updateEmptyState()
    }
  }

  private func updateEmptyState() {
    if documents.isEmpty {
      var configuration = UIContentUnavailableConfiguration.empty()
      configuration.image = UIImage(systemName: "doc.viewfinder")
      configuration.text = "문서가 없습니다"
      configuration.secondaryText = "카메라로 첫 문서를 스캔해 보세요."
      configuration.button = .filled()
      configuration.button.title = "스캔 시작"
      configuration.button.image = UIImage(systemName: "camera")
      configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in
        self?.scanDocument()
      }
      contentUnavailableConfiguration = configuration
    } else if filteredDocuments.isEmpty {
      var configuration = UIContentUnavailableConfiguration.search()
      configuration.text = "검색 결과가 없습니다"
      configuration.secondaryText = "문서 이름이나 OCR 내용의 다른 단어를 입력해 보세요."
      contentUnavailableConfiguration = configuration
    } else {
      contentUnavailableConfiguration = nil
    }
  }
}

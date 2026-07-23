import SwiftData
import UIKit

@MainActor
final class FolderListViewController: UITableViewController {
  var onScanFolder: ((ScanFolder) -> Void)?

  private let environment: UIKitAppEnvironment
  private var folders: [ScanFolder] = []

  init(environment: UIKitAppEnvironment) {
    self.environment = environment
    super.init(style: .insetGrouped)
    title = "ClearScan"
    navigationItem.largeTitleDisplayMode = .always
    tabBarItem.title = "라이브러리"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "FolderCell")
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "folder.badge.plus"),
      style: .plain,
      target: self,
      action: #selector(addFolder)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = "새 폴더"
    refreshControl = UIRefreshControl()
    refreshControl?.addTarget(self, action: #selector(reloadFolders), for: .valueChanged)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadFolders()
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 2 }

  override func tableView(
    _ tableView: UITableView,
    numberOfRowsInSection section: Int
  ) -> Int {
    section == 0 ? 1 : folders.count
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  ) -> String? {
    section == 1 ? "내 폴더" : nil
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "FolderCell", for: indexPath)
    var configuration = UIListContentConfiguration.subtitleCell()

    if indexPath.section == 0 {
      configuration.text = "새 문서 스캔"
      configuration.secondaryText = "자동 인식과 보정을 한 번에 시작해요."
      configuration.image = UIImage(systemName: "camera.viewfinder")
      configuration.imageProperties.tintColor = .systemBlue
      cell.accessoryType = .disclosureIndicator
    } else {
      let folder = folders[indexPath.row]
      cell.accessibilityIdentifier = "folder.\(folder.name)"
      configuration.text = folder.name
      configuration.secondaryText = "\(folder.documents.count)개 문서"
      configuration.image = UIImage(systemName: "folder.fill")
      configuration.imageProperties.tintColor = .systemBlue
      cell.accessoryType = .disclosureIndicator
    }
    cell.contentConfiguration = configuration
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 0 {
      guard let folder = folders.first else { return }
      onScanFolder?(folder)
      return
    }

    let folder = folders[indexPath.row]
    let detail = FolderDetailViewController(environment: environment, folder: folder)
    detail.onScan = { [weak self] folder, document in
      guard let self else { return }
      if let tabBar = self.tabBarController as? RootTabBarController {
        tabBar.showCamera(folder: folder, document: document)
      } else {
        self.onScanFolder?(folder)
      }
    }
    navigationController?.pushViewController(detail, animated: true)
  }

  override func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard indexPath.section == 1 else { return nil }
    let folder = folders[indexPath.row]
    let delete = UIContextualAction(style: .destructive, title: "삭제") { [weak self] _, _, finish in
      guard let self else { return finish(false) }
      do {
        try self.environment.repository.deleteFolder(folder)
        self.reloadFolders()
        finish(true)
      } catch {
        self.presentError(error, title: "폴더를 삭제하지 못했어요")
        finish(false)
      }
    }
    return UISwipeActionsConfiguration(actions: [delete])
  }

  @objc private func reloadFolders() {
    do {
      folders = try environment.fetchFolders()
      tableView.reloadData()
    } catch {
      presentError(error, title: "폴더를 불러오지 못했어요")
    }
    refreshControl?.endRefreshing()
  }

  @objc private func addFolder() {
    let alert = UIAlertController(
      title: "새 폴더",
      message: "문서를 찾기 쉬운 이름을 입력하세요.",
      preferredStyle: .alert
    )
    alert.addTextField { field in
      field.placeholder = "예: 자격증"
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "취소", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "만들기", style: .default) { [weak self, weak alert] _ in
        guard let self else { return }
        do {
          _ = try self.environment.repository.createFolder(
            name: alert?.textFields?.first?.text ?? ""
          )
          self.reloadFolders()
        } catch {
          self.presentError(error, title: "폴더를 만들지 못했어요")
        }
      })
    present(alert, animated: true)
  }
}

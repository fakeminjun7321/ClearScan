import UIKit

@MainActor
final class RootTabBarController: UITabBarController {
  private let environment: UIKitAppEnvironment
  private lazy var cameraViewController = CameraViewController(environment: environment)

  init(environment: UIKitAppEnvironment) {
    self.environment = environment
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureAppearance()

    let library = FolderListViewController(environment: environment)
    library.onScanFolder = { [weak self] folder in
      self?.showCamera(folder: folder)
    }

    viewControllers = [
      navigationController(
        root: library,
        title: "라이브러리",
        imageName: "folder"
      ),
      navigationController(
        root: cameraViewController,
        title: "촬영",
        imageName: "camera.viewfinder"
      ),
      navigationController(
        root: GoogleWorkspaceViewController(environment: environment),
        title: "Google",
        imageName: "g.circle"
      ),
      navigationController(
        root: SettingsViewController(),
        title: "설정",
        imageName: "gearshape"
      ),
    ]
  }

  func showCamera(folder: ScanFolder, document: ScanDocument? = nil) {
    cameraViewController.setDestination(folder: folder, document: document)
    selectedIndex = 1
  }

  private func navigationController(
    root: UIViewController,
    title: String,
    imageName: String
  ) -> UINavigationController {
    let navigation = UINavigationController(rootViewController: root)
    navigation.navigationBar.prefersLargeTitles = true
    navigation.tabBarItem = UITabBarItem(
      title: title,
      image: UIImage(systemName: imageName),
      selectedImage: UIImage(systemName: imageName + ".fill")
    )
    return navigation
  }

  private func configureAppearance() {
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    tabBar.standardAppearance = appearance
    tabBar.scrollEdgeAppearance = appearance
    tabBar.tintColor = .systemBlue

    let navigationAppearance = UINavigationBarAppearance()
    navigationAppearance.configureWithDefaultBackground()
    UINavigationBar.appearance().standardAppearance = navigationAppearance
    UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
    UINavigationBar.appearance().compactAppearance = navigationAppearance
  }
}

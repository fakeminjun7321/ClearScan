import GoogleSignIn
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    GIDSignIn.sharedInstance.handle(url)
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: "Default Configuration",
      sessionRole: connectingSceneSession.role
    )
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var environment: UIKitAppEnvironment?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let window = UIWindow(windowScene: windowScene)
    do {
      let environment = try UIKitAppEnvironment()
      self.environment = environment
      window.rootViewController = RootTabBarController(environment: environment)
    } catch {
      window.rootViewController = StartupErrorViewController(error: error)
    }
    self.window = window
    window.makeKeyAndVisible()
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    _ = GIDSignIn.sharedInstance.handle(url)
  }
}

private final class StartupErrorViewController: UIViewController {
  private let startupError: Error

  init(error: Error) {
    startupError = error
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    var configuration = UIContentUnavailableConfiguration.empty()
    configuration.image = UIImage(systemName: "externaldrive.badge.exclamationmark")
    configuration.text = "저장소를 열지 못했어요"
    configuration.secondaryText = startupError.localizedDescription
    contentUnavailableConfiguration = configuration
  }
}

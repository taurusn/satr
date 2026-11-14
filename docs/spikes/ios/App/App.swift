// Spike I(a) app shell: one window, the page full screen inside the safe area, a run chosen by launch arguments
// (-LinenMode fixtures|paint|bench|touch|loop|idle, -LinenBoard big-500|big-2000, -LinenMinutes 10).
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
    func application(_ application: UIApplication, configurationForConnecting s: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: s.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = HostController()
        w.makeKeyAndVisible()
        window = w
    }
}

@MainActor
final class HostController: UIViewController {
    var page: Page?
    let runner = Runner()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !runner.started else { return }
        runner.started = true
        Task { await runner.run(in: self) }
    }

    /// A fresh page filling the safe area; the old one, if any, is torn down first.
    func newPage() -> Page {
        page?.tearDown()
        let p = Page(frame: view.bounds)
        p.web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(p.web)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            p.web.leadingAnchor.constraint(equalTo: g.leadingAnchor), p.web.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            p.web.topAnchor.constraint(equalTo: g.topAnchor), p.web.bottomAnchor.constraint(equalTo: g.bottomAnchor),
        ])
        view.layoutIfNeeded()
        page = p
        return p
    }
}

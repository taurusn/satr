import Foundation

enum AppIdentity {
    static let fallbackBundleIdentifier = "com.satr.reader"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
    }

    static var documentTabGroup: String {
        identifier("documents")
    }

    static var filePresenterQueue: String {
        identifier("file-presenter")
    }

    static func identifier(_ component: String) -> String {
        "\(bundleIdentifier).\(component)"
    }
}

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LinenKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LinenKit", targets: ["LinenKit"]),
    ],
    targets: [
        .target(
            name: "LinenKit",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "LinenKitTests",
            dependencies: ["LinenKit"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

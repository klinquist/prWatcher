// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "prWatcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "prWatcher", targets: ["PRWatcherApp"])
    ],
    targets: [
        .target(name: "PRWatcherCore"),
        .executableTarget(
            name: "PRWatcherApp",
            dependencies: ["PRWatcherCore"]
        ),
        .testTarget(
            name: "PRWatcherCoreTests",
            dependencies: ["PRWatcherCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)

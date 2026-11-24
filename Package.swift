// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacWatcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacWatcher", targets: ["MacWatcher"])
    ],
    targets: [
        .executableTarget(
            name: "MacWatcher",
            path: "Sources/MacWatcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "MacWatcherTests",
            dependencies: ["MacWatcher"],
            path: "Tests/MacWatcherTests"
        )
    ]
)

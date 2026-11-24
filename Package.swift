// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BurnBlame",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BurnBlame", targets: ["BurnBlame"])
    ],
    targets: [
        .executableTarget(
            name: "BurnBlame",
            path: "Sources/BurnBlame",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "BurnBlameTests",
            dependencies: ["BurnBlame"],
            path: "Tests/BurnBlameTests"
        )
    ]
)

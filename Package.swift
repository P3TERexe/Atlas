// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Atlas",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "Atlas",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/Atlas"
        ),
        .testTarget(
            name: "AtlasTests",
            dependencies: ["Atlas"],
            path: "Tests/AtlasTests"
        ),
    ]
)

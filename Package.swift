// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shotnix",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2"),
    ],
    targets: [
        .target(
            name: "ShotnixCore",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ShotnixCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Shotnix",
            dependencies: [
                "ShotnixCore",
            ],
            path: "Sources/Shotnix"
        ),
        .testTarget(
            name: "ShotnixCoreTests",
            dependencies: [
                "ShotnixCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Tests/ShotnixCoreTests"
        ),
    ]
)

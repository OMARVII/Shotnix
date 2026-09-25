// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shotnix",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Vendored (MIT, from sindresorhus/KeyboardShortcuts 2.4.x) with one
        // patch: its `Bundle.module`-based localization crashed released .app
        // bundles on machines other than the build machine (issue #25) — the
        // vendored copy locates its resource bundle in Contents/Resources.
        .package(path: "Vendor/KeyboardShortcuts"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
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

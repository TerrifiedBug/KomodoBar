// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "KomodoBar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "KomodoBar", targets: ["KomodoBar"]),
        // Lowercase "komodobar" would case-collide with the "KomodoBar" app
        // product in .build/ on case-insensitive filesystems, so the CLI product
        // is suffixed to keep the two binaries distinct.
        .executable(name: "komodobar-cli", targets: ["KomodoBarCLI"]),
        .library(name: "KomodoBarCore", targets: ["KomodoBarCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
    ],
    targets: [
        // Pure-logic library shared by the app and the CLI. No UI, fully testable.
        .target(
            name: "KomodoBarCore",
            swiftSettings: swiftSettings
        ),
        // The menu-bar app. Hand-assembled into a .app by Scripts/package_app.sh.
        .executableTarget(
            name: "KomodoBar",
            dependencies: [
                "KomodoBarCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: swiftSettings
        ),
        // Headless CLI over the same Core (depends on nothing macOS-only).
        .executableTarget(
            name: "KomodoBarCLI",
            dependencies: ["KomodoBarCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "KomodoBarCoreTests",
            dependencies: ["KomodoBarCore"],
            swiftSettings: swiftSettings
        ),
    ]
)

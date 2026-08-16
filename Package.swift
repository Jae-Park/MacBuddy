// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacBuddy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacBuddy", targets: ["MacBuddy"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "MacBuddy",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MacBuddy",
            resources: [
                .copy("Assets/macbuddy-mint-frames-48.png"),
                .copy("Assets/macbuddy-chip-frames-48.png"),
                .copy("Assets/macbuddy-cake-frames-48.png")
            ]
        ),
        .testTarget(
            name: "MacBuddyTests",
            dependencies: ["MacBuddy"],
            path: "Tests/MacBuddyTests"
        )
    ]
)

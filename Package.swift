// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacBuddy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacBuddy", targets: ["MacBuddy"])
    ],
    targets: [
        .executableTarget(
            name: "MacBuddy",
            path: "Sources/MacBuddy",
            resources: [
                .copy("Assets/macbuddy-mint-frames-48.png"),
                .copy("Assets/macbuddy-chip-frames-48.png"),
                .copy("Assets/macbuddy-cake-frames-48.png")
            ]
        )
    ]
)

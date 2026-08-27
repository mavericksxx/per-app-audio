// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PerAppVolume",
    platforms: [.macOS("14.4")],
    targets: [
        // Swift 5 language mode: the render path deliberately uses a heap
        // UnsafeMutablePointer shared with a Core Audio IO block, which Swift 6
        // strict concurrency cannot express without noise that hides real bugs.
        .target(
            name: "AudioRoutingEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PerAppAudio",
            dependencies: ["AudioRoutingEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

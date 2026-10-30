// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModePin",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ModePinCore"
        ),
        .testTarget(
            name: "ModePinCoreTests",
            dependencies: ["ModePinCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

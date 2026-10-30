// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModePin",
    platforms: [.macOS(.v13)],
    targets: [
        // Declarations for the private IOAVService functions in IOKit.
        .target(
            name: "CIOAVService",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "ModePinCore",
            dependencies: ["CIOAVService"]
        ),
        .testTarget(
            name: "ModePinCoreTests",
            dependencies: ["ModePinCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cleanshot-webp-converter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CleanShotWebPCore"),
        .executableTarget(name: "cleanshot-webp-converter", dependencies: ["CleanShotWebPCore"]),
        .testTarget(
            name: "CleanShotWebPCoreTests",
            dependencies: ["CleanShotWebPCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

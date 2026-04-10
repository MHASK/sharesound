// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SharedSound",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SharedSoundCore", targets: ["SharedSoundCore"])
    ],
    targets: [
        .target(
            name: "SharedSoundCore",
            path: "Sources/SharedSoundCore"
        ),
        .testTarget(
            name: "SharedSoundCoreTests",
            dependencies: ["SharedSoundCore"],
            path: "Tests/SharedSoundCoreTests"
        )
    ]
)

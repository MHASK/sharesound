// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SharedSound",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SharedSoundCore", targets: ["SharedSoundCore"]),
        .executable(name: "SharedSoundApp", targets: ["SharedSoundApp"])
    ],
    targets: [
        .target(
            name: "SharedSoundCore",
            path: "Sources/SharedSoundCore"
        ),
        .executableTarget(
            name: "SharedSoundApp",
            dependencies: ["SharedSoundCore"],
            path: "Sources/SharedSoundApp"
        ),
        .testTarget(
            name: "SharedSoundCoreTests",
            dependencies: ["SharedSoundCore"],
            path: "Tests/SharedSoundCoreTests"
        )
    ]
)

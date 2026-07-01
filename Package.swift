// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalFlow",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LocalFlow",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)

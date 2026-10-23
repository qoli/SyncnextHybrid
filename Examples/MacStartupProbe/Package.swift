// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacStartupProbe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../AetherEngine"),
        .package(path: "../../FFmpegBuild")
    ],
    targets: [.executableTarget(
        name: "MacStartupProbe",
        dependencies: [
            .product(name: "AetherEngine", package: "AetherEngine"),
            .product(name: "AetherLibavutil", package: "FFmpegBuild")
        ]
    )]
)

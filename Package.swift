// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SyncnextHybrid",
    platforms: [
        .tvOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SyncnextHybrid",
            targets: ["SyncnextHybrid"]
        ),
    ],
    dependencies: [
        .package(path: "AetherEngine"),
        .package(path: "FFmpegBuild"),
    ],
    targets: [
        .target(
            name: "SyncnextHybrid",
            dependencies: [
                .product(name: "AetherEngine", package: "AetherEngine"),
                .product(name: "Libavcodec", package: "FFmpegBuild"),
                .product(name: "Libavformat", package: "FFmpegBuild"),
                .product(name: "Libavutil", package: "FFmpegBuild"),
                .product(name: "Libswresample", package: "FFmpegBuild"),
            ],
            exclude: [
                "Resources/black-proxy.mp4",
            ],
            resources: [
                .copy("Resources/black-proxy.ts"),
            ]
        ),
        .testTarget(
            name: "SyncnextHybridTests",
            dependencies: [
                "SyncnextHybrid",
                .product(name: "AetherEngine", package: "AetherEngine"),
                .product(name: "Libavcodec", package: "FFmpegBuild"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lumi",
    platforms: [.macOS(.v15)],
    dependencies: [
        // 播放内核：HDR / 杜比视界 / Atmos / 全格式容器 / ASS/PGS 字幕
        .package(url: "https://github.com/superuser404notfound/AetherEngine", from: "7.36.0"),
    ],
    targets: [
        .executableTarget(
            name: "Lumi",
            dependencies: [
                .product(name: "AetherEngine", package: "AetherEngine"),
            ],
            path: "Sources/Lumi",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LumiProbe",
            dependencies: [
                .product(name: "AetherEngine", package: "AetherEngine"),
            ],
            path: "Sources/LumiProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

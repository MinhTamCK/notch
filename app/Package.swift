// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0"),
        .package(url: "https://github.com/swhitty/FlyingFox", from: "0.27.0"),
    ],
    targets: [
        .executableTarget(
            name: "NotchApp",
            dependencies: [
                "DynamicNotchKit",
                .product(name: "FlyingFox", package: "FlyingFox"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "notch-hook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

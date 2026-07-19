// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored (MIT) with reduced content margins — see Vendor/DynamicNotchKit/Package.swift
        .package(path: "Vendor/DynamicNotchKit"),
        .package(url: "https://github.com/swhitty/FlyingFox", from: "0.27.0"),
    ],
    targets: [
        // Pure, testable logic shared by the app and the hook binary.
        .target(name: "NotchCore"),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
        .executableTarget(
            name: "NotchApp",
            dependencies: [
                "NotchCore",
                "DynamicNotchKit",
                .product(name: "FlyingFox", package: "FlyingFox"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "notch-hook",
            dependencies: ["NotchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

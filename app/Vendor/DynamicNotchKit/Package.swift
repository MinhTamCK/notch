// swift-tools-version: 6.0
// Vendored from https://github.com/MrKai77/DynamicNotchKit (MIT) with one change:
// content safe-area margins reduced 15 → 8 for a tighter panel.
import PackageDescription

let package = Package(
    name: "DynamicNotchKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DynamicNotchKit",
            targets: ["DynamicNotchKit"]
        )
    ],
    targets: [
        .target(
            name: "DynamicNotchKit",
            path: "Sources"
        )
    ]
)

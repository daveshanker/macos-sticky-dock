// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DockAnchor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DockAnchor",
            path: "Sources/DockAnchor"
        )
    ]
)

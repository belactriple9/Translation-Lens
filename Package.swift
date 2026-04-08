// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Lens",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "Lens", targets: ["Lens"]),
    ],
    targets: [
        .executableTarget(
            name: "Lens",
            path: "Sources/Lens"
        ),
    ]
)

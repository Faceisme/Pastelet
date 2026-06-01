// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Pastelet",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Pastelet", targets: ["Pastelet"])
    ],
    targets: [
        .executableTarget(
            name: "Pastelet",
            path: "Sources/Pastelet"
        )
    ]
)

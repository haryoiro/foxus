// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "foxus",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "Foxus", targets: ["Foxus"]),
    ],
    targets: [
        .target(
            name: "Foxus",
            path: "Sources/Foxus"
        ),
        .testTarget(
            name: "FoxusTests",
            dependencies: ["Foxus"],
            path: "Tests/FoxusTests"
        ),
    ]
)

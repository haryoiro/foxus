// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "foxus",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "Foxus", targets: ["Foxus"]),
        .executable(name: "foxus-debug", targets: ["FoxusDebug"]),
    ],
    targets: [
        .target(
            name: "Foxus",
            path: "Sources/Foxus"
        ),
        .executableTarget(
            name: "FoxusDebug",
            dependencies: ["Foxus"],
            path: "Sources/FoxusDebug"
        ),
        .testTarget(
            name: "FoxusTests",
            dependencies: ["Foxus"],
            path: "Tests/FoxusTests"
        ),
    ]
)

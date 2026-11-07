// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ADoor",
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "ADoor", targets: ["ADoor"])
    ],
    targets: [
        .target(name: "ADoor", path: "Sources/ADoor"),
        .testTarget(name: "ADoorTests", dependencies: ["ADoor"], path: "Tests/ADoorTests")
    ]
)

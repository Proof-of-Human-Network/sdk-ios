// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "POHKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "POHKit", targets: ["POHKit"]),
    ],
    targets: [
        .target(
            name: "POHKit",
            path: "Sources/POHKit"
        ),
        .testTarget(
            name: "POHKitTests",
            dependencies: ["POHKit"],
            path: "Tests/POHKitTests"
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "proofofhuman",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "proofofhuman", targets: ["proofofhuman"]),
    ],
    targets: [
        .target(
            name: "proofofhuman",
            path: "Sources/proofofhuman"
        ),
        .testTarget(
            name: "proofofhumanTests",
            dependencies: ["proofofhuman"],
            path: "Tests/proofofhumanTests"
        ),
    ]
)

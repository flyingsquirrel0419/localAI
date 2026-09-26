// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalAICore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LocalAICore", targets: ["LocalAICore"])
    ],
    targets: [
        .target(
            name: "LocalAICore",
            path: "Sources/LocalAICore"
        ),
        .testTarget(
            name: "LocalAICoreTests",
            dependencies: ["LocalAICore"],
            path: "Tests/LocalAICoreTests"
        )
    ]
)

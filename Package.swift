// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkdownViewer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ViewerKit", targets: ["ViewerKit"]),
        .library(name: "ViewerCore", targets: ["ViewerCore"]),
        .library(name: "ViewerUI", targets: ["ViewerUI"]),
        .executable(name: "MarkdownViewer", targets: ["MarkdownViewer"]),
    ],
    targets: [
        .target(name: "ViewerKit"),
        .target(name: "ViewerCore", dependencies: ["ViewerKit"]),
        .target(name: "ViewerUI", dependencies: ["ViewerKit", "ViewerCore"]),
        .executableTarget(
            name: "MarkdownViewer",
            dependencies: ["ViewerKit", "ViewerCore", "ViewerUI"]
        ),
        .testTarget(name: "ViewerKitTests", dependencies: ["ViewerKit"]),
        .testTarget(name: "ViewerCoreTests", dependencies: ["ViewerCore"]),
    ]
)

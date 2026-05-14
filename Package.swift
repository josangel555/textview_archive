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
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.3.0"),
    ],
    targets: [
        .target(name: "ViewerKit"),
        .target(
            name: "ViewerCore",
            dependencies: [
                "ViewerKit",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .target(
            name: "ViewerUI",
            dependencies: ["ViewerKit", "ViewerCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "MarkdownViewer",
            dependencies: ["ViewerKit", "ViewerCore", "ViewerUI"]
        ),
        .testTarget(name: "ViewerKitTests", dependencies: ["ViewerKit"]),
        .testTarget(name: "ViewerCoreTests", dependencies: ["ViewerCore"]),
    ]
)

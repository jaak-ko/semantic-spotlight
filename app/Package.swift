// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SemanticSpotlight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SemanticSpotlight",
            path: "Sources/SemanticSpotlight"
        )
    ]
)

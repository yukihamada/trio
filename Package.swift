// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Trio",
            path: "Sources/Trio"
        )
    ]
)

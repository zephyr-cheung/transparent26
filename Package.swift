// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "transparent26",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "transparent26",
            path: "Sources/transparent26"
        )
    ]
)

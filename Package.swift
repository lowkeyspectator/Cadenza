// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cadenza",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Cadenza", path: "Sources/Cadenza")
    ]
)

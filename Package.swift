// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cadenza",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Cadenza", path: "Sources/Cadenza")
    ]
)

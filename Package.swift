// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clipshelf",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Clipshelf", path: "Sources/Clipshelf")
    ]
)

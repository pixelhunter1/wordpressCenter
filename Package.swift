// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WPCenter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WPCenter", path: "Sources/WPCenter"),
    ]
)

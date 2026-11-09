// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ResourceMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ResourceMonitor", path: "Sources/ResourceMonitor")
    ]
)

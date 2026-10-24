// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PortKit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PortKit", path: "Sources/PortKit"),
        .testTarget(name: "PortKitTests", dependencies: ["PortKit"], path: "Tests/PortKitTests"),
    ]
)

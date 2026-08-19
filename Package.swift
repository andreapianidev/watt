// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Watt",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WattKit"),
        .executableTarget(name: "WattHelper", dependencies: ["WattKit"]),
        .executableTarget(name: "WattApp", dependencies: ["WattKit"]),
    ]
)

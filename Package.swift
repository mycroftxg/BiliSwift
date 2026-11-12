// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "HarborBili", platforms: [.macOS("26.0")],
    products: [.executable(name: "HarborBili", targets: ["HarborBili"])],
    targets: [
        .target(name: "HarborCore"),
        .executableTarget(name: "HarborBili", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborPlaybackTests", dependencies: ["HarborBili", "HarborCore"])
    ]
)

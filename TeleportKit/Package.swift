// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeleportKit", targets: ["TeleportKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.8.0"),
    ],
    targets: [
        .target(name: "TeleportKit", dependencies: ["Citadel"]),
        .target(name: "TeleportCLICore", dependencies: ["TeleportKit"]),
        .testTarget(name: "TeleportCLICoreTests", dependencies: ["TeleportCLICore"]),
    ]
)

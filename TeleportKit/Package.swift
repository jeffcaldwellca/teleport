// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeleportKit", targets: ["TeleportKit"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "TeleportKit", dependencies: []),
    ]
)

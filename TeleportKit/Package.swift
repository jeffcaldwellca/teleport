// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeleportKit", targets: ["TeleportKit"]),
        .executable(name: "tport", targets: ["tport"]),
    ],
    dependencies: [
        // Citadel 0.12.1 with one local patch; see Vendor/Citadel/TELEPORT-PATCHES.md.
        .package(path: "Vendor/Citadel"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "TeleportKit", dependencies: ["Citadel"]),
        .target(name: "TeleportCLICore", dependencies: ["TeleportKit"]),
        .testTarget(name: "TeleportKitTests", dependencies: ["TeleportKit"]),
        .testTarget(name: "TeleportCLICoreTests", dependencies: ["TeleportCLICore"]),
        .executableTarget(
            name: "tport",
            dependencies: [
                "TeleportKit",
                "TeleportCLICore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)

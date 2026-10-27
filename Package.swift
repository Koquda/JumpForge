// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JumpForge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "JumpCore", targets: ["JumpCore"]),
        .library(name: "JumpMedia", targets: ["JumpMedia"]),
        .library(name: "JumpUI", targets: ["JumpUI"]),
        .executable(name: "JumpForge", targets: ["JumpForgeDesktop"])
    ],
    targets: [
        .target(name: "JumpCore"),
        .target(name: "JumpMedia", dependencies: ["JumpCore"]),
        .target(name: "JumpUI", dependencies: ["JumpCore", "JumpMedia"]),
        .executableTarget(name: "JumpForgeDesktop", dependencies: ["JumpUI"]),
        .testTarget(name: "JumpCoreTests", dependencies: ["JumpCore"]),
        .testTarget(name: "JumpMediaTests", dependencies: ["JumpMedia", "JumpCore"])
    ]
)

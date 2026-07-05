// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenFinder",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenFinderCore", targets: ["OpenFinderCore"]),
        .executable(name: "OpenFinder", targets: ["OpenFinderApp"])
    ],
    targets: [
        .target(name: "OpenFinderCore"),
        .executableTarget(
            name: "OpenFinderApp",
            dependencies: ["OpenFinderCore"],
            path: "Sources/OpenFinderApp"
        ),
        .testTarget(name: "OpenFinderCoreTests", dependencies: ["OpenFinderCore"])
    ]
)

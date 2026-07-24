// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenFinder",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenFinderCore", targets: ["OpenFinderCore"]),
        .executable(name: "OpenFinder", targets: ["OpenFinderApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0")
    ],
    targets: [
        .target(
            name: "OpenFinderCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "OpenFinderApp",
            dependencies: ["OpenFinderCore"],
            path: "Sources/OpenFinderApp"
        ),
        .testTarget(name: "OpenFinderCoreTests", dependencies: ["OpenFinderCore"]),
        .testTarget(name: "OpenFinderAppTests", dependencies: ["OpenFinderApp", "OpenFinderCore"])
    ]
)

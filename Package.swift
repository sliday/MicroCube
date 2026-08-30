// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MicroCubeMetal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MicroCubeMetal", targets: ["MicroCubeMetal"])
    ],
    targets: [
        .executableTarget(
            name: "MicroCubeMetal",
            resources: [.copy("Shaders"), .copy("Resources")]
        ),
        .testTarget(
            name: "MicroCubeMetalTests",
            dependencies: ["MicroCubeMetal"]
        )
    ],
    swiftLanguageVersions: [.v5]
)

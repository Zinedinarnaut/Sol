// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sol",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SolDLSM", targets: ["SolDLSM"]),
        .executable(name: "Sol", targets: ["Sol"])
    ],
    targets: [
        .target(
            name: "SolDLSM",
            path: "Sources/SolDLSM",
            resources: [
                .process("Models")
            ]
        ),
        .executableTarget(
            name: "Sol",
            dependencies: ["SolDLSM"],
            path: "Sources/Sol",
            resources: [
                .process("Metal")
            ]
        ),
        .testTarget(
            name: "SolTests",
            dependencies: ["Sol", "SolDLSM"],
            path: "Tests/SolTests"
        )
    ]
)

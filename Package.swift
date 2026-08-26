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
    dependencies: [
        .package(url: "https://github.com/sindresorhus/DockProgress.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/SwiftPackageIndex/SemanticVersion.git", from: "0.5.3"),
        .package(url: "https://github.com/SvenTiigi/WhatsNewKit.git", from: "2.2.1"),
        .package(url: "https://github.com/markiv/SwiftUI-Shimmer.git", from: "1.5.1"),
        .package(url: "https://github.com/joogps/Glur.git", from: "1.1.0"),
        .package(url: "https://github.com/Lakr233/ColorfulX.git", from: "6.1.0"),
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
            dependencies: [
                "SolDLSM",
                .product(name: "DockProgress", package: "DockProgress"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SemanticVersion", package: "SemanticVersion"),
                .product(name: "WhatsNewKit", package: "WhatsNewKit"),
                .product(name: "Shimmer", package: "SwiftUI-Shimmer"),
                .product(name: "Glur", package: "Glur"),
                .product(name: "ColorfulX", package: "ColorfulX"),
            ],
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

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SECDatasetBuilder",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "SECDatasetBuilderCore",
            targets: ["SECDatasetBuilderCore"]
        ),
        .library(
            name: "SECDatasetBuilderUI",
            targets: ["SECDatasetBuilderUI"]
        ),
        .executable(
            name: "sec-dataset-builder",
            targets: ["sec-dataset-builder"]
        )
    ],
    targets: [
        .target(
            name: "SECDatasetBuilderCore"
        ),
        .target(
            name: "SECDatasetBuilderUI",
            dependencies: ["SECDatasetBuilderCore"]
        ),
        .executableTarget(
            name: "sec-dataset-builder",
            dependencies: ["SECDatasetBuilderCore"]
        ),
        .testTarget(
            name: "SECDatasetBuilderTests",
            dependencies: ["SECDatasetBuilderCore"]
        )
    ]
)

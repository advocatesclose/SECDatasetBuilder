// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SECDatasetBuilder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SECDatasetBuilderCore",
            targets: ["SECDatasetBuilderCore"]
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

// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "ConductorShared",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "ConductorFoundation", targets: ["ConductorFoundation"]),
        .library(name: "SharedConductorData", targets: ["SharedConductorData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/sqlite-data", exact: "1.6.6"),
    ],
    targets: [
        .target(
            name: "ConductorFoundation",
            path: "ConductorFoundation/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SharedConductorData",
            dependencies: [
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "SharedConductorData/Sources",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SharedConductorDataTests",
            dependencies: [
                "SharedConductorData",
            ],
            path: "SharedConductorData/Tests",
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

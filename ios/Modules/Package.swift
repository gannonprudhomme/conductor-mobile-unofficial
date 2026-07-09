// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "ConductorModules",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        .library(name: "ConductorData", targets: ["ConductorData"]),
        .library(name: "ConductorMain", targets: ["ConductorMain"]),
        .library(name: "ConductorWorkspaces", targets: ["ConductorWorkspaces"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/sqlite-data", exact: "1.6.6"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", exact: "1.25.5"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.14.1"),
        .package(url: "https://github.com/pointfreeco/swift-navigation.git", from: "2.10.1"),
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "603.0.2"),
    ],
    targets: [
        .target(
            name: "ConductorData",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "Foundations/ConductorData/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorWorkspaces",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "ConductorData",
            ],
            path: "ConductorWorkspaces/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorMain",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "ConductorWorkspaces",
            ],
            path: "ConductorMain/Sources",
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

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
        .library(name: "ConductorChat", targets: ["ConductorChat"]),
        .library(name: "ConductorDesign", targets: ["ConductorDesign"]),
        .library(name: "ConductorMain", targets: ["ConductorMain"]),
        .library(name: "ConductorMobileData", targets: ["ConductorMobileData"]),
        .library(name: "ConductorWorkspaces", targets: ["ConductorWorkspaces"]),
    ],
    dependencies: [
        .package(name: "ConductorShared", path: "../../shared"),
        .package(url: "https://github.com/JakubMazur/lucide-icons-swift", exact: "1.23.0"),
        .package(url: "https://github.com/pointfreeco/sqlite-data", exact: "1.6.6"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", exact: "1.25.5"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.14.1"),
        .package(url: "https://github.com/pointfreeco/swift-navigation.git", from: "2.10.1"),
        .package(url: "https://github.com/pointfreeco/swift-sharing", exact: "2.9.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "603.0.2"),
    ],
    targets: [
        .target(
            name: "ConductorMobileData",
            dependencies: [
                .product(name: "SharedConductorData", package: "ConductorShared"),
                .product(name: "ConductorFoundation", package: "ConductorShared"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "Foundations/ConductorMobileData/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorChat",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SharedConductorData", package: "ConductorShared"),
                .product(name: "LucideIcons", package: "lucide-icons-swift"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "ConductorMobileData",
                "ConductorDesign",
            ],
            path: "ConductorChat/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorDesign",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "SharedConductorData", package: "ConductorShared"),
                .product(name: "LucideIcons", package: "lucide-icons-swift"),
                "ConductorMobileData",
            ],
            path: "ConductorDesign/Sources",
            resources: [
                .process("Assets.xcassets"),
                .process("Fonts"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorWorkspaces",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SharedConductorData", package: "ConductorShared"),
                .product(name: "LucideIcons", package: "lucide-icons-swift"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "ConductorMobileData",
                "ConductorDesign",
            ],
            path: "ConductorWorkspaces/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorMain",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "ConductorChat",
                "ConductorWorkspaces",
            ],
            path: "ConductorMain/Sources",
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

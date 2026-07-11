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
        .library(name: "ConductorFoundation", targets: ["ConductorFoundation"]),
        .library(name: "ConductorChat", targets: ["ConductorChat"]),
        .library(name: "ConductorDesign", targets: ["ConductorDesign"]),
        .library(name: "ConductorData", targets: ["ConductorData"]),
        .library(name: "ConductorMain", targets: ["ConductorMain"]),
        .library(name: "ConductorSessions", targets: ["ConductorSessions"]),
        .library(name: "ConductorWorkspaces", targets: ["ConductorWorkspaces"]),
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-spm.git", exact: "4.6.0"),
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
            name: "ConductorFoundation",
            path: "Foundations/ConductorFoundation/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorChat",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "ConductorData",
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
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "LucideIcons", package: "lucide-icons-swift"),
                "ConductorData",
            ],
            path: "ConductorDesign/Sources",
            resources: [
                .process("Assets.xcassets"),
                .process("Fonts"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorData",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "ConductorFoundation",
            ],
            path: "Foundations/ConductorData/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorSessions",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "LucideIcons", package: "lucide-icons-swift"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "ConductorDesign",
                "ConductorData",
            ],
            path: "ConductorSessions/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorWorkspaces",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "LucideIcons", package: "lucide-icons-swift"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "ConductorDesign",
                "ConductorData",
            ],
            path: "ConductorWorkspaces/Sources",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ConductorMain",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "ConductorChat",
                "ConductorSessions",
                "ConductorWorkspaces",
            ],
            path: "ConductorMain/Sources",
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

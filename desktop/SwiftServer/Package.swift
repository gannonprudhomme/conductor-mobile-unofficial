// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "ConductorMobileServer",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "conductor-mobile-server", targets: ["ConductorMobileServerExecutable"])
    ],
    dependencies: [
        .package(name: "ConductorShared", path: "../../shared"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.25.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.14.1"),
        .package(url: "https://github.com/pointfreeco/sqlite-data", exact: "1.6.6"),
    ],
    targets: [
        .target(
            name: "ConductorMobileServer",
            dependencies: [
                .product(name: "SharedConductorData", package: "ConductorShared"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "ConductorMobileServerExecutable",
            dependencies: ["ConductorMobileServer"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ConductorMobileServerTests",
            dependencies: [
                "ConductorMobileServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
